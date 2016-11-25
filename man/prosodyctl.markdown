---
author:
- 'Dwayne Bent <dbb.1@liqd.org>'
- Kim Alvefur
date: '2015-12-23'
section: 1
title: PROSODYCTL
---

NAME
====

prosodyctl - Manage a Prosody XMPP server

SYNOPSIS
========

    prosodyctl command [--help]

DESCRIPTION
===========

prosodyctl is the control tool for the Prosody XMPP server. It may be
used to control the server daemon and manage users.

prosodyctl needs to be executed with sufficient privileges to perform
its commands. This typically means executing prosodyctl as the root
user. If a user named "prosody" is found then prosodyctl will change to
that user before executing its commands.

COMMANDS
========

User Management
---------------

In the following commands users are identified by a Jabber ID, jid, of
the usual form: user@domain.

adduser jid
:   Adds a user with Jabber ID, jid, to the server. You will be prompted
    to enter the user's password.

passwd jid
:   Changes the password of an existing user with Jabber ID, jid. You
    will be prompted to enter the user's new password.

deluser jid
:   Deletes an existing user with Jabber ID, jid, from the server.

Daemon Management
-----------------

Although prosodyctl has commands to manage the prosody daemon it is
recommended that you utilize your distributions daemon management
features if you attained Prosody through a package.

To perform daemon control commands prosodyctl needs a pidfile value
specified in `/etc/prosody/prosody.cfg.lua`. Failure to do so will cause
prosodyctl to complain.

start
:   Starts the prosody server daemon. If run as root prosodyctl will
    attempt to change to a user named "prosody" before executing. This
    operation will block for up to five seconds to wait for the server
    to execute.

stop
:   Stops the prosody server daemon. This operation will block for up to
    five seconds to wait for the server to stop executing.

restart
:   Restarts the prosody server daemon. Equivalent to running prosodyctl
    stop followed by prosodyctl start.

reload
:   Signals the prosody server daemon to reload configuration and reopen
    log files.

status
:   Prints the current execution status of the prosody server daemon.

Certificates
------------

prosodyctl can create self-signed certificates, certificate requests and
private keys for use with Prosody. Commands are of the form
`prosodyctl cert subcommand`. Commands take a list of hosts to be
included in the certificate.

request hosts
:   Create a certificate request (CSR) file for submission to a
    certificate authority. Multiple hosts can be given, sub-domains are
    automatically included.

generate hosts
:   Generate a self-signed certificate.

key host \[size\]
:   Generate a private key of 'size' bits (defaults to 2048). Invoked
    automatically by 'request' and 'generate' if needed.

config hosts
:   Produce a config file for the list of hosts. Invoked automatically
    by 'request' and 'generate' if needed.

Debugging
---------

prosodyctl can also show some information about the environment,
dependencies and such to aid in debugging.

about
:   Shows environment, various paths used by Prosody and
    installed dependencies.

check \[what\]
:   Performs various sanity checks on the configuration, DNS setup and
    configured TLS certificates. `what` can be one of `config`, `dns`
    and `certs` to run only that check.

Ejabberd Compatibility
----------------------

ejabberd is another XMPP server which provides a comparable control
tool, ejabberdctl, to control its server's operations. prosodyctl
implements some commands which are compatible with ejabberdctl. For
details of how these commands work you should see ejabberdctl(8).

    register user server password

    unregister user server

OPTIONS
=======

`--help`
:   Display help text for the specified command.

FILES
=====

`/etc/prosody/prosody.cfg.lua`
:   The main prosody configuration file. prosodyctl reads this to
    determine the process ID file of the prosody server daemon and to
    determine if a host has been configured.

ONLINE
======

More information may be found online at: <https://prosody.im/>
