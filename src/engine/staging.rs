//! `tmp_sibling` + `mv` from `lib/helpers/tmp.sh`: a file is replaced by
//! renaming a staging file written beside it, so a reader never sees it half
//! written and the rename stays on one filesystem.

use std::fs::{File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

use crate::Error;

/// Replaces `dest` with `bytes`. The staging file is created `0600`, as
/// `mktemp` creates it, and takes the mode of an existing `dest`.
pub fn write_beside(dest: &Path, bytes: &[u8]) -> Result<(), Error> {
    let (path, mut file) = create_sibling(dest, None)?;
    let written = file
        .write_all(bytes)
        .and_then(|()| match std::fs::metadata(dest) {
            Ok(meta) if meta.is_file() => std::fs::set_permissions(&path, meta.permissions()),
            _ => Ok(()),
        })
        .and_then(|()| std::fs::rename(&path, dest));
    if let Err(e) = written {
        let _ = std::fs::remove_file(&path);
        return Err(Error::io(dest, e));
    }
    Ok(())
}

pub fn write_new_beside(dest: &Path, bytes: &[u8]) -> Result<(), Error> {
    let (path, mut file) = create_sibling(dest, Some(".agentsync-stage."))?;
    let written = file
        .write_all(bytes)
        .and_then(|()| file.sync_all())
        .and_then(|()| std::fs::hard_link(&path, dest));
    let _ = std::fs::remove_file(&path);
    if let Err(e) = written {
        return Err(Error::io(dest, e));
    }
    Ok(())
}

fn create_sibling(dest: &Path, hidden_prefix: Option<&str>) -> Result<(PathBuf, File), Error> {
    let pid = std::process::id();
    let mut attempt = 0u64;
    loop {
        let path = if let Some(prefix) = hidden_prefix {
            dest.parent()
                .unwrap_or(Path::new("."))
                .join(format!("{prefix}{pid}{attempt:04}"))
        } else {
            let mut name = dest.as_os_str().to_owned();
            name.push(format!(".{pid}{attempt:04}"));
            PathBuf::from(name)
        };
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
        match options.open(&path) {
            Ok(file) => return Ok((path, file)),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => attempt += 1,
            Err(e) => return Err(Error::io(dest, e)),
        }
    }
}

#[cfg(all(test, unix))]
mod tests {
    use std::os::unix::fs::PermissionsExt;

    use super::*;

    fn mode(path: &Path) -> u32 {
        std::fs::metadata(path).unwrap().permissions().mode() & 0o777
    }

    #[test]
    fn a_new_file_is_private_like_mktemp_and_a_replaced_file_keeps_its_mode() {
        let dir = tempfile::tempdir().unwrap();
        let fresh = dir.path().join(".sync-manifest");
        write_beside(&fresh, b"a\th\n").unwrap();
        assert_eq!(std::fs::read(&fresh).unwrap(), b"a\th\n");
        assert_eq!(mode(&fresh), 0o600);

        let kept = dir.path().join(".gitignore");
        std::fs::write(&kept, "old\n").unwrap();
        std::fs::set_permissions(&kept, std::fs::Permissions::from_mode(0o644)).unwrap();
        write_beside(&kept, b"new\n").unwrap();
        assert_eq!(std::fs::read(&kept).unwrap(), b"new\n");
        assert_eq!(mode(&kept), 0o644);
        assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 2);
    }

    #[test]
    fn a_read_only_destination_is_still_replaced_and_keeps_its_mode() {
        let dir = tempfile::tempdir().unwrap();
        let locked = dir.path().join("locked.yaml");
        std::fs::write(&locked, "original\n").unwrap();
        std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o444)).unwrap();
        write_beside(&locked, b"rewritten\n").unwrap();
        assert_eq!(std::fs::read(&locked).unwrap(), b"rewritten\n");
        assert_eq!(mode(&locked), 0o444);
        assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 1);
    }

    #[test]
    fn a_missing_parent_is_an_error_that_leaves_nothing_behind() {
        let dir = tempfile::tempdir().unwrap();
        assert!(write_beside(&dir.path().join("missing/x"), b"x").is_err());
        assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 0);
    }

    #[test]
    fn exclusive_write_preserves_an_occupied_destination() {
        let dir = tempfile::tempdir().unwrap();
        let dest = dir.path().join("mcp.json");
        std::fs::write(&dest, b"private bytes").unwrap();
        assert!(write_new_beside(&dest, b"new bytes").is_err());
        assert_eq!(std::fs::read(&dest).unwrap(), b"private bytes");
        assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 1);
    }
}
