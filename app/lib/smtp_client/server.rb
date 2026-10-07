# frozen_string_literal: true

module SMTPClient
  class Server

    attr_reader :hostname
    attr_reader :port
    attr_accessor :ssl_mode
    attr_reader :username
    attr_reader :password

    # username/password are only set for authenticated relays (e.g. SendGrid,
    # SES); direct-to-MX servers never authenticate.
    def initialize(hostname, port: 25, ssl_mode: SSLModes::AUTO, username: nil, password: nil)
      @hostname = hostname
      @port = port
      @ssl_mode = ssl_mode
      @username = username
      @password = password
    end

    def authenticated?
      @username.present? && @password.present?
    end

    # Return all IP addresses for this server by resolving its hostname.
    # IPv6 addresses will be returned first, unless disabled.
    #
    # Set SMTP_CLIENT_DISABLE_IPV6=true to deliver over IPv4 only. Needed on
    # hosts (e.g. Fly.io) whose egress IPv6 has no matching PTR record —
    # Gmail permanently rejects such IPv6 connections (550 5.7.1), and a
    # permanent error means no fallback to the IPv4 endpoint is attempted.
    #
    # @return [Array<SMTPClient::Endpoint>]
    def endpoints
      ips = []

      unless ENV["SMTP_CLIENT_DISABLE_IPV6"] == "true"
        DNSResolver.local.aaaa(@hostname).each do |ip|
          ips << Endpoint.new(self, ip)
        end
      end

      DNSResolver.local.a(@hostname).each do |ip|
        ips << Endpoint.new(self, ip)
      end

      ips
    end

  end
end
