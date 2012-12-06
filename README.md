# @title README

# README

## Name

fluent-plugin-groonga

## Description

Fluent-plugin-groonga is fluentd plugin collection for
[groonga](http://groonga.org/) users. Groonga users can replicate
their data by fluent-plugin-groonga.

Fluent-plugin-groonga includes an input plugin and an output
plugin. Both of them are named `groonga`.

The input plugin provides groonga compatible interface. It means that
HTTP and GQTP interface. You can use the input plugin as groonga
server. The input plugin receives groonga commands and sends them to
the output plugin through some fluentds.

The output plugin sends received groonga commands to groonga. The
output plugin supports all interfaces, HTTP, GQTP and command
interface.

You can replicate your data by using `copy` output plugin.

## Install

    % gem install fluent-plugin-groonga

## Usage

* About configuration: See doc/text/configuration.md or
  [Web](http://www.rubydoc.info/gems/fluent-plugin-groonga/file/configuration.md).

## Authors

* Kouhei Sutou `<kou@clear-code.com>`

## License

LGPL 2.1. See doc/text/lgpl-2.1.txt for details.

(Kouhei Sutou has a right to change the license including
contributed patches.)

## Mailing list

* English: [groonga-talk](https://lists.sourceforge.net/lists/listinfo/groonga-talk)
* Japanese: [groonga-dev](http://lists.sourceforge.jp/mailman/listinfo/groonga-dev)

## Thanks

* ...
