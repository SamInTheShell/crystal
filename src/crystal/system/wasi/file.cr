require "../unix/file"

# :nodoc:
module Crystal::System::File
  protected def system_init(mode : String, blocking : Bool) : Nil
  end

  def self.chmod(path, mode)
    raise NotImplementedError.new "Crystal::System::File.chmod"
  end

  def self.chown(path, uid : Int, gid : Int, follow_symlinks)
    raise NotImplementedError.new "Crystal::System::File.chown"
  end

  private def system_chown(uid : Int, gid : Int)
    raise NotImplementedError.new "Crystal::System::File#system_chown"
  end

  def self.realpath(path)
    raise NotImplementedError.new "Crystal::System::File.realpath"
  end

  def self.utime(atime : ::Time, mtime : ::Time, filename : String) : Nil
    timespecs = uninitialized LibC::Timespec[2]
    timespecs[0] = Crystal::System::Time.to_timespec(atime)
    timespecs[1] = Crystal::System::Time.to_timespec(mtime)

    if LibC.utimensat(LibC::AT_FDCWD, filename, timespecs, 0) != 0
      raise ::File::Error.from_errno("Error setting time on file", file: filename)
    end
  end

  def self.delete(path : String, *, raise_on_missing : Bool) : Bool
    err = LibC.unlink(path.check_no_null_byte)
    if err != -1
      true
    elsif !raise_on_missing && ::File::NotFoundError.os_error?(Errno.value)
      false
    else
      raise ::File::Error.from_errno("Error deleting file", file: path)
    end
  end
end
