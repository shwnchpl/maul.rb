maul.rb
=======

Like a splitting maul, but for logs that are made of text instead of
wood.

Installation
------------

With Ruby installed, maul.rb can be installed as follows using the
provided Makefile::

    # make install

Usage
-----

maul.rb is a simple log multiplexing daemon for POSIX systems. The
daemon opens a named pipe at a specified location (see "Configuration")
which can then be written to in a manual or automated fashion to
generate logs that are split into separate "trees" that are further into
directories and files based on configuration and write-time.

Writes to the named pipe are in the following format::

  [command]:[tree name]:[payload]

The following commands are supported::

  log       - Write payload to appropriate file in log tree.
  timeout   - Set rolling timeout, in seconds.
  commit    - Stop writing to current file, regardless of timeout.

``[tree name]`` may be any valid directory name that does not contain
colon characters. All messages that are logged to a tree using the log
command are written into the same file while the rolling timeout for
that tree has not expired or the commit command has not been sent to
that tree.

Within trees, files are sorted into directories in the following
format::

    YEAR/MONTH_NUMBER/ISO-8601-TIMESTAMP.txt

For example, an initial (out of rolling timeout window) log command
issued at 11:17 UTC on December 31st, 2022 will generate the file
``2022/12/2022-12-31T111700-0500.txt``. Subsequent writes within the
associate tree's timeout window will be aggregated into this file
(unless a commit command is sent).

Example Usage
-------------

As a complete example, consider a system where maul.rb is running with
the default configuration and the following commands are run at 11:17 on
December 31st, 2022::

    $ echo -e "timeout:foo:30\nlog:foo:Hello" > /tmp/maul.fifo
    $ echo -e "log:bar:Hello" > /tmp/maul.fifo

This will create the following file tree::

    $ tree /tmp/maul
    /tmp/maul
    ├── bar
    │   └── 2022
    │       └── 12
    │           ├── 2022-12-31T111725-0500.txt
    └── foo
        └── 2022
            └── 12
                ├── 2022-12-31T111703-0500.txt

    6 directories, 2 files

Both of these files contain the same text::

    Hello

After one minute, at 11:18, the following command is run::

    $ echo -e "log:foo:World!\nlog:bar:World!" > /tmp/maul.fifo
    $ echo -e "timeout:foo:900" > /tmp/maul.fifo

Now, the directory tree looks like this::

    $ tree /tmp/maul
    /tmp/maul
    ├── bar
    │   └── 2022
    │       └── 12
    │           ├── 2022-12-31T111725-0500.txt
    └── foo
        └── 2022
            └── 12
                ├── 2022-12-31T111703-0500.txt
                ├── 2022-12-31T111811-0500.txt

    6 directories, 3 files

Because 15 minutes have not elapsed since the most recent write to the
``bar`` tree, the write goes to a new file. In the ``foo`` tree, since
over 30 seconds have elapsed, the logged payload goes into a new file.
At this point, the ``bar`` tree contains one file with the contents::

    Hello
    World!

And the ``foo`` tree contains two files, one with the same contents as
before and a newer one with the contents::

    World!

Additionally, the ``foo`` tree timeout has been updated to 15 minutes.
Next, after one more minute, at 11:19, the following commands are run::

    $ echo -e "commit:bar:" > /tmp/maul.fifo
    $ echo -e "log:foo:Hello again!" > /tmp/maul.fifo
    $ echo -e "log:bar:Hello again!" > /tmp/maul.fifo

Now, the tree looks like this::

    $ tree /tmp/maul
    /tmp/maul
    ├── bar
    │   └── 2022
    │       └── 12
    │           ├── 2022-12-31T111725-0500.txt
    │           └── 2022-12-31T111924-0500.txt
    └── foo
        └── 2022
            └── 12
                ├── 2022-12-31T111703-0500.txt
                ├── 2022-12-31T111811-0500.txt
                └── 2022-12-31T111949-0500.txt

    6 directories, 5 files

This may seem confusing. Since the commit command has been used on the
bar tree, it makes sense that a new file has been created, but the
timeout for the foo tree was set to 15 minutes, so why was a new file
created?

The key is that the timeout for the foo tree was set **after** the most
recently sent log message. Because of this, the old timeout of 30
seconds was still active when the "Hello again!" log command was sent so
this was the last timeout applied to that tree. If an additional message
had been logged, it would have gone in the same file as would any
message sent within the next 15 minutes, but because this didn't happen
the message at 11:19 ended up in a new file.

In short, updated timeouts apply to all log commands sent **after** the
timeout has been updated, but they do not retroactively cause previously
logged messages to keep the currently opened file alive for longer.

Other Considerations
--------------------

It is critical to note that writes to the FIFO must open the file,
perform a write, and close the file before the daemon receives the
commands to be processed. Each open-write-close cycle by a client is
treated as a single transaction by the daemon. In order to pipe STDOUT
from some program to the FIFO and have each line be treated as its own
command, a shim like the included ``fifo-tee.sh`` should be used.

Additionally, newlines in payloads must be escaped as '\n' as
end-of-line is used to detect end of command.

``fifo-tee.sh``::

    #!/bin/bash

    while read -r f; do
        echo $f > $1
    done

Example invocation::

    $ log-to-stdout | fifo-tee.sh /tmp/maul.fifo

Configuration
-------------

maul.rb looks for YAML configuration files at
``/etc/maul/config.yaml`` and ``$HOME/.config/maul/config.yaml``.
Configuration options specified in user config files takes precedence
over their corresponding options in the system configuration file. The
following keys are supported::

    fifo_path       - Full path at which to create the maul FIFO.
                      (default: /tmp/maul.fifo)
    root_path       - Path to the root directory tree.
                      (default: /tmp/maul)
    default_timeout - Default tree timeout, in seconds.
                      (default: 900)

Example configuration file::

    ---
    maul:
      fifo_path: "/run/maul.pipe"
      root_path: "/var/maul/root"
      default_timeout: 60

When tree timeout is specified using the ``timeout`` command, this is
stored persistently in the associated tree in a file named
``.config.yaml``. The only key in this file is ``timeout`` and it can be
updated manually without consequence.

Example tree config file::

    ---
    maul:
      timeout: 60

Okay, cool, but why would I want any of this?
---------------------------------------------

Fair question. One compelling use case for maul.rb is chat logging with
"intelligent" dynamic aggregation.

For example, some bot/service can be created that pipes messages from
several rooms/channels on some chat platform into the maul.rb pipe. Each
chat room can be assigned its own tree and timeout can be set depending
on the frequency with which people in the room converse.

With the right configuration, each "conversation" in each room will
automatically be logged into a file named based on that conversation's
start time and sorted into the tree associated with its room. Such a bot
could also, for example, send manual "commit" messages to each tree at
some preset time (such as midnight) to ensure individual log files never
exceed a certain length. Make the maul.rb root a git repository and
create a cron job to automatically commit and push on some sensible
interval, and you've got version controlled split logs.

For an example of a Telegram logging bot intended to be used with
maul.rb, see `lumberjill.rb`_.

.. _lumberjill.rb: https://github.com/shwnchpl/lumberjill.rb

License
-------

maul.rb is the work of Shawn M. Chapla and it is released under the MIT
license. For more details, see the LICENSE file.
