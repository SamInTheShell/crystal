require "../unix/file_descriptor"

# :nodoc:
module Crystal::System::FileDescriptor
  def self.from_stdio(fd)
    # TODO: WASI doesn't offer a way to detect if a 'fd' is a TTY.
    IO::FileDescriptor.new(fd).tap(&.flush_on_newline=(true))
  end

  def self.fcntl(fd, cmd, arg = 0)
    FileDescriptor.fcntl(fd, cmd, arg)
  end

  private def system_fcntl(cmd, arg = 0)
    FileDescriptor.fcntl(fd, cmd, arg)
  end

  def self.get_blocking(fd : Handle)
    fcntl(fd, LibC::F_GETFL) & LibC::O_NONBLOCK == 0
  end

  def self.set_blocking(fd : Handle, value : Bool)
    current_flags = fcntl(fd, LibC::F_GETFL)
    new_flags = current_flags
    if value
      new_flags &= ~LibC::O_NONBLOCK
    else
      new_flags |= LibC::O_NONBLOCK
    end
    fcntl(fd, LibC::F_SETFL, new_flags) unless new_flags == current_flags
  end

  protected def system_blocking_init(blocking : Bool?)
  end

  private def system_reopen(other : IO::FileDescriptor)
    raise NotImplementedError.new "Crystal::System::FileDescriptor#system_reopen"
  end

  private def system_lock(blocking, exclusive)
    raise NotImplementedError.new "Crystal::System::File#system_lock"
  end

  private def system_unlock
    raise NotImplementedError.new "Crystal::System::File#system_unlock"
  end

  private def system_echo(enable : Bool)
    raise NotImplementedError.new "Crystal::System::FileDescriptor#system_echo"
  end

  private def system_echo(enable : Bool, & : ->)
    raise NotImplementedError.new "Crystal::System::FileDescriptor#system_echo"
  end

  private def system_raw(enable : Bool)
    raise NotImplementedError.new "Crystal::System::FileDescriptor#system_raw"
  end

  private def system_raw(enable : Bool, & : ->)
    raise NotImplementedError.new "Crystal::System::FileDescriptor#system_raw"
  end
end
