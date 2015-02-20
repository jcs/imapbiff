#!/usr/bin/env ruby
#
# IMAP biff with notifications supporting multiple accounts and IMAP IDLE.
#
# To configure, create a YAML file at ~/.imapbiffrc file like so:
#
# ---
# :accounts:
# - :hostname: mail.example.com
#   :username: user@example.com
# - :hostname: mail2.example.com
#   :username: user2@example.com
#   :label: "[user2 mail] "
#
# For OS X, `brew install terminal-notifier` to install terminal notifier
# command line application.  If your passwords are in keychain, you can avoid
# having them in plaintext in your ~/.imapbiffrc file, and they will be fetched
# from `security` on startup.  You can add them to your keychain with:
#
# $ security add-internet-password -a <username>  -s <hostname> -w <password>
#

#
# Copyright (c) 2015 joshua stein <jcs@jcs.org>
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
#
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
# 3. The name of the author may not be used to endorse or promote products
#    derived from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR "AS IS" AND ANY EXPRESS OR
# IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
# OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
# IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
# INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
# NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
# DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
# THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
# THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#

require "net/imap"
require "open3"
require "yaml"

class Notifier
  def self.notify(options = {})
    options = {
      :title => "imapbiff",
      :message => options[:message],
    }.merge(options)

    if options[:label]
      options[:title] = "#{options[:label]}#{options[:title]}"
      options.delete(:label)
    end

    if RUBY_PLATFORM.match(/darwin/)
      options[:sender] = "com.apple.Mail"
      options.each do |k,v|
        if v[0] == "\"" || v[0] == "["
          options[k] = "\\" + v
        end
      end

      args = [
        "/Applications/terminal-notifier.app/Contents/MacOS/terminal-notifier",
      ] + options.map{|k,v| [ "-#{k}", v ] }.flatten

      system(*args)
    else
      puts "need to notify: [#{title}] [#{message}]"
    end
  end
end

class IMAPConnection
  attr_reader :hostname, :username, :password, :mailbox
  attr_accessor :label

  def initialize(hostname, username, password, mailbox = "inbox")
    @hostname = hostname
    @username = username
    @password = password
    @mailbox = mailbox

    @imap = nil
  end

  def imap
    if @imap
      return @imap
    end

    @imap = Net::IMAP.new(self.hostname, "imaps", ssl = true)
    @imap.authenticate("LOGIN", self.username, self.password)

    self.notify({ :message => "Connected to #{self.hostname} as " <<
      "#{self.username}" })

    @imap
  end

  def idle_loop
    while true do
      begin
        self.imap.examine(self.mailbox)

        while true do
          unseen = nil

          imap.idle do |resp|
            if resp.is_a?(Net::IMAP::UntaggedResponse) && resp.name == "EXISTS"
              unseen = resp.data
              imap.idle_done
            end
          end

          if !unseen
            next
          end

          flags = imap.fetch(unseen, "FLAGS").first.attr.values.first
          if flags.include?(:Seen)
            next
          end

          imap.examine(self.mailbox)

          attrs = { :body => "Unable to read message" }

          begin
            [ :from, :subject ].each do |f|
              attrs[f] = imap.fetch(unseen,
                "BODY.PEEK[HEADER.FIELDS (#{f.to_s.upcase})]").
                first.attr.values.first.strip.gsub(/^[^:]+: ?/, "")

              if m = attrs[f].to_s.match(/^=\?([^\?]+)\?([QB])\?(.+)\?=$/)
                if m[2].downcase == "q"
                  attrs[f] = m[3].unpack("M*").first
                elsif m[2].downcase == "b"
                  attrs[f] = m[3].unpack("m*").first
                end
              end
            end

            encoding = nil
            textpart = 0

            struct = imap.fetch(unseen, "BODYSTRUCTURE").
              first.attr.values.first
            case struct.class.to_s
            when "Net::IMAP::BodyTypeMultipart"
              struct.parts.each_with_index do |part,x|
                if part.media_type.downcase == "text" &&
                part.subtype.downcase == "plain"
                  textpart = "1.#{x + 1}"
                  encoding = part.encoding
                  break
                end
              end

            when "Net::IMAP::BodyTypeText"
              if struct.subtype.downcase == "plain"
                textpart = 1
                encoding = struct.encoding
              end
            end

            if textpart == 0
              attrs[:body] = "HTML message"
            else
              attrs[:body] = imap.fetch(unseen,
                "BODY.PEEK[#{textpart}]<0.200>").first.attr.values.first

              if encoding.to_s.match(/quoted/i)
                attrs[:body] = attrs[:body].unpack("M*").first
              elsif encoding.to_s.match(/base64/i)
                attrs[:body] = attrs[:body].unpack("m*").first
              end
            end

          rescue => e
            puts e.inspect
          end

          self.notify({ :title => attrs[:from], :subtitle =>
            attrs[:subject], :message => attrs[:body] })
        end

      rescue IOError => e
        @imap = nil
        sleep 5

      rescue StandardError => e
        self.notify({ :title => "[#{self.hostname}] imapbiff error: " <<
          "#{e.class}", :message => e.message })
        sleep 5
      end
    end
  end

  def notify(options)
    if self.label.to_s != ""
      options[:label] = self.label
    end

    Notifier.notify(options)
  end
end

class IMAPBiff
  attr_reader :connections

  def initialize(config)
    @connections = []

    config[:accounts].each do |acct|
      if !acct[:password]
        if RUBY_PLATFORM.match(/darwin/)
          IO.popen([ "/usr/bin/security", "find-internet-password", "-g",
          "-a", acct[:username], "-s", acct[:hostname] ],
          :err => [ :child, :out ]) do |sec|
            while sec && !sec.eof?
              if m = sec.gets.match(/^password: "(.+)"$/)
                acct[:password] = m[1]
              end
            end
          end
        end
      end

      if acct[:password].to_s == ""
        Notifier.notify({ :message => "failed to initialize " <<
          "#{acct[:username]}@#{acct[:hostname]}: no password found" })
        exit 1
      end

      c = IMAPConnection.new(acct[:hostname], acct[:username], acct[:password])
      if acct[:label]
        c.label = acct[:label]
      end

      @connections.push c
    end
  end

  def run!
    Thread.abort_on_exception = true

    threads = @connections.map{|c|
      Thread.new(c) {
        connection = c
        c.idle_loop
      }
    }

    threads.each{|th| th.join }
  end
end

IMAPBiff.new(YAML.load_file("#{ENV["HOME"]}/.imapbiffrc")).run!
