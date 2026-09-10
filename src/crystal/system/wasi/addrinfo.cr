module Crystal::System::Addrinfo
  alias Handle = NoReturn

  protected def initialize(addrinfo : Handle)
    # Unreachable (`Handle` is `NoReturn`), but the compiler requires every
    # instance variable to be initialized in every constructor.
    @family = ::Socket::Family::UNSPEC
    @type = ::Socket::Type::STREAM
    @protocol = ::Socket::Protocol::IP
    @size = 0
    raise NotImplementedError.new("Crystal::System::Addrinfo#initialize")
  end

  def system_ip_address : ::Socket::IPAddress
    raise NotImplementedError.new("Crystal::System::Addrinfo#system_ip_address")
  end

  def to_unsafe
    raise NotImplementedError.new("Crystal::System::Addrinfo#to_unsafe")
  end

  def self.getaddrinfo(domain, service, family, type, protocol, timeout, flags = 0) : Handle
    raise NotImplementedError.new("Crystal::System::Addrinfo.getaddrinfo")
  end

  def self.next_addrinfo(addrinfo : Handle) : Handle
    raise NotImplementedError.new("Crystal::System::Addrinfo.next_addrinfo")
  end

  def self.free_addrinfo(addrinfo : Handle)
    raise NotImplementedError.new("Crystal::System::Addrinfo.free_addrinfo")
  end
end
