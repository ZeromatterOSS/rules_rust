// Copyright 2020 The Bazel Authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

mod flags;
mod options;
mod output;
mod pw_args;
mod rustc;
mod util;
mod worker;

#[cfg(windows)]
use std::collections::HashMap;
#[cfg(windows)]
use std::collections::VecDeque;
use std::fmt;
use std::fs::{self, copy, OpenOptions};
use std::io;
use std::path::PathBuf;
use std::process::{exit, Command, Stdio};
#[cfg(windows)]
use std::time::{SystemTime, UNIX_EPOCH};

use crate::options::{options, Options, SubprocessPipeliningMode};
use crate::output::{process_output, LineOutput};
#[cfg(windows)]
use crate::util::read_file_to_array;

#[derive(Debug)]
pub(crate) struct ProcessWrapperError(String);

impl fmt::Display for ProcessWrapperError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "process wrapper error: {}", self.0)
    }
}

impl std::error::Error for ProcessWrapperError {}

macro_rules! debug_log {
    ($($arg:tt)*) => {
        if std::env::var_os("RULES_RUST_PROCESS_WRAPPER_DEBUG").is_some() {
            eprintln!($($arg)*);
        }
    };
}

enum TemporaryPath {
    File(PathBuf),
    Directory(PathBuf),
}

struct TemporaryPathGuard {
    paths: Vec<TemporaryPath>,
}

impl TemporaryPathGuard {
    fn new() -> Self {
        Self { paths: Vec::new() }
    }

    fn track_file(&mut self, path: PathBuf) {
        self.paths.push(TemporaryPath::File(path));
    }

    fn track_directory(&mut self, path: PathBuf) {
        self.paths.push(TemporaryPath::Directory(path));
    }

    fn cleanup(&mut self) {
        for path in self.paths.drain(..).rev() {
            match path {
                TemporaryPath::File(path) => {
                    let _ = fs::remove_file(path);
                }
                TemporaryPath::Directory(path) => {
                    let _ = fs::remove_dir_all(path);
                }
            }
        }
    }
}

impl Drop for TemporaryPathGuard {
    fn drop(&mut self) {
        self.cleanup();
    }
}

#[cfg(windows)]
struct ParsedDependencyArgs {
    dependency_paths: Vec<PathBuf>,
    filtered_args: Vec<String>,
}

#[cfg(windows)]
fn get_dependency_search_paths_from_args(
    initial_args: &[String],
) -> Result<ParsedDependencyArgs, ProcessWrapperError> {
    let mut dependency_paths = Vec::new();
    let mut filtered_args = Vec::new();
    let mut argfile_contents: HashMap<String, Vec<String>> = HashMap::new();

    let mut queue: VecDeque<(String, Option<String>)> =
        initial_args.iter().map(|arg| (arg.clone(), None)).collect();

    while let Some((arg, parent_argfile)) = queue.pop_front() {
        let target = match &parent_argfile {
            Some(p) => argfile_contents
                .entry(format!("{}.filtered", p))
                .or_default(),
            None => &mut filtered_args,
        };

        if arg == "-L" {
            let next_arg = queue.front().map(|(a, _)| a.as_str());
            if let Some(path) = next_arg.and_then(|n| n.strip_prefix("dependency=")) {
                dependency_paths.push(PathBuf::from(path));
                queue.pop_front();
            } else {
                target.push(arg);
            }
        } else if let Some(path) = arg.strip_prefix("-Ldependency=") {
            dependency_paths.push(PathBuf::from(path));
        } else if let Some(argfile_path) = arg.strip_prefix('@') {
            let lines = read_file_to_array(argfile_path).map_err(|e| {
                ProcessWrapperError(format!("unable to read argfile {}: {}", argfile_path, e))
            })?;

            for line in lines {
                queue.push_back((line, Some(argfile_path.to_string())));
            }

            target.push(format!("@{}.filtered", argfile_path));
        } else {
            target.push(arg);
        }
    }

    for (path, content) in argfile_contents {
        fs::write(&path, content.join("\n")).map_err(|e| {
            ProcessWrapperError(format!("unable to write filtered argfile {}: {}", path, e))
        })?;
    }

    Ok(ParsedDependencyArgs {
        dependency_paths,
        filtered_args,
    })
}

// On Windows, collapse many `-Ldependency` entries into one directory to stay
// under rustc's search-path limits.
#[cfg(windows)]
fn consolidate_dependency_search_paths(
    args: &[String],
) -> Result<(Vec<String>, Option<PathBuf>), ProcessWrapperError> {
    let parsed = get_dependency_search_paths_from_args(args)?;
    let ParsedDependencyArgs {
        dependency_paths,
        mut filtered_args,
    } = parsed;

    if dependency_paths.is_empty() {
        return Ok((filtered_args, None));
    }

    let unique_suffix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    let dir_name = format!(
        "rules_rust_process_wrapper_deps_{}_{}",
        std::process::id(),
        unique_suffix
    );

    let unified_dir = std::env::temp_dir().join(&dir_name);
    fs::create_dir_all(&unified_dir).map_err(|e| {
        ProcessWrapperError(format!(
            "unable to create unified dependency directory {}: {}",
            unified_dir.display(),
            e
        ))
    })?;

    crate::util::consolidate_deps_into(&dependency_paths, &unified_dir);

    filtered_args.push(format!("-Ldependency={}", unified_dir.display()));

    Ok((filtered_args, Some(unified_dir)))
}

#[cfg(not(windows))]
fn consolidate_dependency_search_paths(
    args: &[String],
) -> Result<(Vec<String>, Option<PathBuf>), ProcessWrapperError> {
    Ok((args.to_vec(), None))
}

#[cfg(unix)]
fn symlink_dir(src: &std::path::Path, dest: &std::path::Path) -> Result<(), std::io::Error> {
    std::os::unix::fs::symlink(src, dest)
}

#[cfg(windows)]
fn symlink_dir(src: &std::path::Path, dest: &std::path::Path) -> Result<(), std::io::Error> {
    std::os::windows::fs::symlink_dir(src, dest)
}

enum CacheSeedOutcome {
    AlreadyPresent,
    Seeded,
    NotFound,
}

fn cache_root_from_execroot_ancestor(cwd: &std::path::Path) -> Option<PathBuf> {
    // Walk upward looking for the output-base `cache` directory.
    for ancestor in cwd.ancestors() {
        if ancestor.file_name().is_some_and(|name| name == "execroot") {
            continue;
        }

        let candidate = ancestor.join("cache");
        if candidate.is_dir() {
            return candidate.canonicalize().ok().or(Some(candidate));
        }
    }

    None
}

fn ensure_cache_loopback_for_path(
    resolved_path: &std::path::Path,
    cache_root: &std::path::Path,
) -> Result<Option<PathBuf>, ProcessWrapperError> {
    let Ok(relative) = resolved_path.strip_prefix(cache_root) else {
        return Ok(None);
    };
    let mut components = relative.components();
    if components
        .next()
        .is_none_or(|component| component.as_os_str() != "repos")
    {
        return Ok(None);
    }
    let Some(version) = components.next() else {
        return Ok(None);
    };
    if components
        .next()
        .is_none_or(|component| component.as_os_str() != "contents")
    {
        return Ok(None);
    }

    let version_dir = cache_root.join("repos").join(version.as_os_str());
    let loopback = version_dir.join("cache");
    if loopback.exists() {
        return Ok(Some(loopback));
    }

    symlink_dir(cache_root, &loopback).map_err(|e| {
        ProcessWrapperError(format!(
            "unable to seed cache loopback {} -> {}: {}",
            cache_root.display(),
            loopback.display(),
            e
        ))
    })?;
    Ok(Some(loopback))
}

fn ensure_cache_loopback_from_args(
    cwd: &std::path::Path,
    child_arguments: &[String],
    cache_root: &std::path::Path,
) -> Result<Option<PathBuf>, ProcessWrapperError> {
    for arg in child_arguments {
        let candidate = cwd.join(arg);
        let Ok(resolved) = candidate.canonicalize() else {
            continue;
        };
        if let Some(loopback) = ensure_cache_loopback_for_path(&resolved, cache_root)? {
            return Ok(Some(loopback));
        }
    }

    Ok(None)
}

fn seed_cache_root_for_current_dir() -> Result<CacheSeedOutcome, ProcessWrapperError> {
    let cwd = std::env::current_dir().map_err(|e| {
        ProcessWrapperError(format!("unable to read current working directory: {e}"))
    })?;
    let dest = cwd.join("cache");
    if dest.exists() {
        return Ok(CacheSeedOutcome::AlreadyPresent);
    }

    if let Some(cache_root) = cache_root_from_execroot_ancestor(&cwd) {
        symlink_dir(&cache_root, &dest).map_err(|e| {
            ProcessWrapperError(format!(
                "unable to seed cache root {} -> {}: {}",
                cache_root.display(),
                dest.display(),
                e
            ))
        })?;
        return Ok(CacheSeedOutcome::Seeded);
    }

    for entry in fs::read_dir(&cwd).map_err(|e| {
        ProcessWrapperError(format!("unable to read current working directory: {e}"))
    })? {
        let entry = entry.map_err(|e| {
            ProcessWrapperError(format!(
                "unable to enumerate current working directory: {e}"
            ))
        })?;
        let Ok(resolved) = entry.path().canonicalize() else {
            continue;
        };

        for ancestor in resolved.ancestors() {
            if ancestor.file_name().is_some_and(|name| name == "cache") {
                symlink_dir(ancestor, &dest).map_err(|e| {
                    ProcessWrapperError(format!(
                        "unable to seed cache root {} -> {}: {}",
                        ancestor.display(),
                        dest.display(),
                        e
                    ))
                })?;
                return Ok(CacheSeedOutcome::Seeded);
            }
        }
    }

    Ok(CacheSeedOutcome::NotFound)
}

/// Runs the standalone process_wrapper path.
pub(crate) fn run_standalone(opts: &Options) -> Result<i32, ProcessWrapperError> {
    let (child_arguments, dep_argfile_cleanup) =
        consolidate_dependency_search_paths(&opts.child_arguments)?;
    let mut temp_path_guard = TemporaryPathGuard::new();
    for path in &opts.temporary_expanded_paramfiles {
        temp_path_guard.track_file(path.clone());
    }
    if let Some(path) = dep_argfile_cleanup {
        temp_path_guard.track_directory(path);
    }
    let cwd = std::env::current_dir().map_err(|e| {
        ProcessWrapperError(format!("unable to read current working directory: {e}"))
    })?;
    let _ = seed_cache_root_for_current_dir();
    if let Some(cache_root) = cache_root_from_execroot_ancestor(&cwd) {
        let _ = ensure_cache_loopback_from_args(&cwd, &child_arguments, &cache_root);
    }

    let mut command = Command::new(opts.executable.clone());
    command
        .args(child_arguments)
        .env_clear()
        .envs(opts.child_environment.clone())
        .stdout(if let Some(stdout_file) = opts.stdout_file.as_deref() {
            OpenOptions::new()
                .create(true)
                .truncate(true)
                .write(true)
                .open(stdout_file)
                .map_err(|e| ProcessWrapperError(format!("unable to open stdout file: {}", e)))?
                .into()
        } else {
            Stdio::inherit()
        })
        .stderr(Stdio::piped());
    debug_log!("{:#?}", command);
    let mut child = command
        .spawn()
        .map_err(|e| ProcessWrapperError(format!("failed to spawn child process: {}", e)))?;

    let mut stderr: Box<dyn io::Write> = if let Some(stderr_file) = opts.stderr_file.as_deref() {
        Box::new(
            OpenOptions::new()
                .create(true)
                .truncate(true)
                .write(true)
                .open(stderr_file)
                .map_err(|e| ProcessWrapperError(format!("unable to open stderr file: {}", e)))?,
        )
    } else {
        Box::new(io::stderr())
    };

    let mut child_stderr = child.stderr.take().ok_or(ProcessWrapperError(
        "unable to get child stderr".to_string(),
    ))?;

    let mut output_file: Option<std::fs::File> = if let Some(output_file_name) =
        opts.output_file.as_deref()
    {
        Some(
            OpenOptions::new()
                .create(true)
                .truncate(true)
                .write(true)
                .open(output_file_name)
                .map_err(|e| ProcessWrapperError(format!("Unable to open output_file: {}", e)))?,
        )
    } else {
        None
    };

    let result = if let Some(format) = opts.rustc_output_format {
        process_output(
            &mut child_stderr,
            stderr.as_mut(),
            output_file.as_mut(),
            move |line| rustc::process_stderr_line(line, format),
        )
    } else {
        process_output(
            &mut child_stderr,
            stderr.as_mut(),
            output_file.as_mut(),
            move |line| Ok(LineOutput::Message(line)),
        )
    };
    result.map_err(|e| ProcessWrapperError(format!("failed to process stderr: {}", e)))?;

    let status = child
        .wait()
        .map_err(|e| ProcessWrapperError(format!("failed to wait for child process: {}", e)))?;
    let code = status.code().unwrap_or(1);
    if code == 0 {
        if let Some(tf) = opts.touch_file.as_deref() {
            OpenOptions::new()
                .create(true)
                .truncate(true)
                .write(true)
                .open(tf)
                .map_err(|e| ProcessWrapperError(format!("failed to create touch file: {}", e)))?;
        }
        if let Some((copy_source, copy_dest)) = opts.copy_output.as_ref() {
            copy(copy_source, copy_dest).map_err(|e| {
                ProcessWrapperError(format!(
                    "failed to copy {} into {}: {}",
                    copy_source, copy_dest, e
                ))
            })?;
        }
    }

    Ok(code)
}

/// Checks whether a standalone worker-pipelining full action can skip rustc.
///
/// Returns `Ok(true)` if the `.rlib` exists (no-op path), `Ok(false)` if no
/// `pipelining_rlib_path` is set or the `.rlib` is missing (must run rustc).
///
/// The main() function inlines this logic for clarity; this helper exists
/// for unit tests in test/main.rs.
#[cfg(test)]
pub(crate) fn check_pipelining_full_prerequisites(
    pipelining_rlib_path: &Option<String>,
) -> Result<bool, ProcessWrapperError> {
    match pipelining_rlib_path {
        Some(rlib_path) if std::path::Path::new(rlib_path).exists() => Ok(true),
        _ => Ok(false),
    }
}

/// Checks whether the standalone .rmeta from the metadata action matches the
/// .rmeta that the full action's rustc produces. Both are from `--emit=metadata`,
/// so they're structurally identical — a byte mismatch means a non-deterministic
/// proc macro produced different SVH values across the two separate rustc
/// invocations, which will cause E0460/E0463 downstream.
///
/// `full_rmeta_path` is a temp file produced by adding `--emit=metadata=<path>`
/// to the full action's rustc invocation. `meta_rmeta_path` is the metadata
/// action's declared .rmeta output (an input to this action).
fn check_svh_consistency(
    full_rmeta_path: &str,
    meta_rmeta_path: &str,
) -> Result<(), String> {
    let full = fs::read(full_rmeta_path)
        .map_err(|e| format!("failed to read full action rmeta {}: {}", full_rmeta_path, e))?;
    let meta = fs::read(meta_rmeta_path)
        .map_err(|e| format!("failed to read metadata action rmeta {}: {}", meta_rmeta_path, e))?;

    if full == meta {
        debug_log!(
            "pipelining SVH check passed: metadata-action and full-action .rmeta match ({} bytes)",
            meta.len()
        );
        return Ok(());
    }

    Err(format!(
        concat!(
            "ERROR: [rules_rust] SVH mismatch detected.\n",
            "The metadata action and full action produced different crate hashes for\n",
            "this crate. This is caused by a non-deterministic proc macro (e.g., one\n",
            "that iterates a HashMap) in this crate's dependency graph.\n",
            "\n",
            "  metadata action .rmeta: {} ({} bytes)\n",
            "  full action .rmeta:     {} ({} bytes)\n",
            "\n",
            "Downstream crates compiled against the metadata .rmeta will fail to link\n",
            "against the full .rlib (E0460 SVH mismatch or E0463 can't find crate).\n",
            "\n",
            "To fix, either:\n",
            "  1. Use worker execution: --strategy=Rustc=worker\n",
            "     (single rustc process per crate, SVH always consistent)\n",
            "  2. Use hollow-rlib pipelining:\n",
            "     --@rules_rust//rust/settings:experimental_pipelined_compilation=hollow_rlib\n",
            "     (tier-consistent graph, safe for all proc macros)\n",
            "  3. Fix the proc macro to use BTreeMap/BTreeSet instead of HashMap/HashSet\n",
            "     (eliminates non-deterministic iteration order)\n",
        ),
        meta_rmeta_path,
        meta.len(),
        full_rmeta_path,
        full.len(),
    ))
}

/// Warning message when a standalone full action must run a second rustc.
const PIPELINING_STANDALONE_WARNING: &str = concat!(
    "WARNING: [rules_rust] Worker pipelining full action executing outside a worker.\n",
    "The metadata action's .rlib side-effect was not found, so a redundant second\n",
    "rustc invocation will run. This happens when Bazel falls back from worker to\n",
    "sandboxed or local execution (both run separate rustc processes). The build\n",
    "will succeed if all proc macros are deterministic; nondeterministic proc macros\n",
    "will be detected via SVH consistency check and fail with a clear diagnostic.\n",
    "\n",
    "To suppress this warning:\n",
    "  1. Use worker execution: --strategy=Rustc=worker (default when supports-multiplex-workers is set)\n",
    "  2. Use hollow-rlib pipelining: --@rules_rust//rust/settings:experimental_pipelined_compilation=hollow_rlib\n",
);

fn main() -> Result<(), ProcessWrapperError> {
    if std::env::args().any(|a| a == "--persistent_worker") {
        return worker::worker_main();
    }

    let mut opts = options().map_err(|e| ProcessWrapperError(e.to_string()))?;

    // Outside worker mode, a full pipelining action can no-op if the metadata
    // action already produced the `.rlib` as a side-effect in the same execroot.
    if opts.pipelining_mode == Some(SubprocessPipeliningMode::Full) {
        if let Some(ref rlib_path) = opts.pipelining_rlib_path {
            if std::path::Path::new(rlib_path).exists() {
                // .rlib side-effect found — metadata action already ran rustc
                // in this execroot. No-op: just touch/copy outputs and exit.
                debug_log!(
                    "pipelining no-op: .rlib already exists at {}, skipping rustc",
                    rlib_path
                );
                if let Some(ref tf) = opts.touch_file {
                    OpenOptions::new()
                        .create(true)
                        .truncate(true)
                        .write(true)
                        .open(tf)
                        .map_err(|e| {
                            ProcessWrapperError(format!("failed to create touch file: {}", e))
                        })?;
                }
                if let Some((ref copy_source, ref copy_dest)) = opts.copy_output {
                    copy(copy_source, copy_dest).map_err(|e| {
                        ProcessWrapperError(format!(
                            "failed to copy {} into {}: {}",
                            copy_source, copy_dest, e
                        ))
                    })?;
                }
                for path in &opts.temporary_expanded_paramfiles {
                    let _ = fs::remove_file(path);
                }
                exit(0);
            } else {
                // .rlib side-effect missing (sandboxed execution or remote leg).
                // Warn and fall through to run a second rustc.
                eprintln!("{}", PIPELINING_STANDALONE_WARNING);
            }
        }
    }

    // SVH consistency check: when the standalone full action must run a second
    // rustc (no .rlib side-effect from the metadata action), inject
    // `--emit=metadata=<temp>` so this rustc also produces a standalone .rmeta.
    // After success, compare it with the metadata action's .rmeta. A byte
    // mismatch means non-deterministic proc macros produced different SVHs.
    // Multiple `--emit` flags are additive in rustc, so this is safe.
    let svh_check_rmeta_path = if opts.pipelining_mode == Some(SubprocessPipeliningMode::Full)
        && opts.pipelining_rmeta_path.is_some()
    {
        let temp_rmeta = format!("{}.svh_check", opts.pipelining_rmeta_path.as_ref().unwrap());
        opts.child_arguments
            .push(format!("--emit=metadata={}", temp_rmeta));
        Some(temp_rmeta)
    } else {
        None
    };

    let code = run_standalone(&opts)?;

    if opts.pipelining_mode == Some(SubprocessPipeliningMode::Full) {
        if code != 0
            && opts
                .pipelining_rlib_path
                .as_ref()
                .is_some_and(|p| !std::path::Path::new(p).exists())
        {
            eprintln!(concat!(
                "\nERROR: [rules_rust] Redundant rustc invocation failed (see warning above).\n",
                "If the error is E0460 (SVH mismatch), switch to hollow-rlib pipelining:\n",
                "  --@rules_rust//rust/settings:experimental_pipelined_compilation=hollow_rlib\n",
            ));
        } else if code == 0 {
            // Rustc succeeded — check for SVH mismatch between the metadata
            // action's .rmeta and the full action's .rmeta (produced by the
            // injected --emit=metadata). Both are standalone .rmeta files from
            // --emit=metadata, so a byte mismatch means different SVH.
            if let (Some(full_rmeta), Some(meta_rmeta)) =
                (&svh_check_rmeta_path, &opts.pipelining_rmeta_path)
            {
                let result = check_svh_consistency(full_rmeta, meta_rmeta);
                // Clean up the temp .rmeta regardless of result.
                let _ = fs::remove_file(full_rmeta);
                if let Err(msg) = result {
                    eprintln!("{}", msg);
                    exit(1);
                }
            }
        }
    }

    // Clean up svh check temp file on failure path too.
    if let Some(ref path) = svh_check_rmeta_path {
        let _ = fs::remove_file(path);
    }

    exit(code)
}

#[cfg(test)]
#[path = "test/main.rs"]
mod test;
