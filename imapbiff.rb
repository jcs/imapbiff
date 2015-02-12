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
# from `security` on startup.
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
  def self.notify(title, message, group = "imapbiff")
    if RUBY_PLATFORM.match(/darwin/)
      system("/Applications/terminal-notifier.app/Contents/MacOS/terminal-notifier",
        "-group", group,
        "-title", title.gsub(/^\[/, "\\["),
        "-message", message.gsub(/^\[/, "\\["),
        "-sender", "com.apple.Mail")
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

    self.notify("imapbiff", "Connected to #{self.hostname} as #{self.username}")

    @imap
  end

  def idle_loop
    while true do
      begin
        self.imap.select(self.mailbox)

        while true do
          unseen = nil

          imap.idle do |resp|
            if resp.is_a?(Net::IMAP::UntaggedResponse) && resp.name == "EXISTS"
              unseen = resp.data
              imap.idle_done
            end
          end

          if unseen
            imap.select(self.mailbox)

            attrs = {}
            [ "from", "subject" ].each do |f|
              attrs[f] = imap.fetch(unseen,
                "BODY.PEEK[HEADER.FIELDS (#{f.upcase})]").
                first.attr.values.first.strip.gsub(/^[^:]+: ?/, "")
            end

            self.notify(attrs["subject"], "From #{attrs["from"]}")
          end
        end

      rescue IOError => e
        @imap = nil
        sleep 5

      rescue StandardError => e
        self.notify("[#{self.hostname}] imapbiff error: #{e.class}", e.message)
        sleep 5
      end
    end
  end

  def notify(title, message)
    if self.label.to_s != ""
      title = self.label + title.to_s
    end

    Notifier.notify(title, message, "#{self.username}@#{self.hostname}")
  end
end

class IMAPBiff
  attr_reader :connections

  def initialize(config)
    @connections = []

    config[:accounts].each do |acct|
      if !acct[:password] && RUBY_PLATFORM.match(/darwin/)
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

      if acct[:password].to_s == ""
        Notifier.notify("imapbiff", "failed to initialize " <<
          "#{acct[:username]}@#{acct[:hostname]}: no password found")
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
