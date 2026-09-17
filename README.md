# Tinny

The Tinny project provides the `tinny` library and the `can` command-line tool.
A Tinny application is a Rust program that defines and configures computers as code.

To make one you create a Cargo project, import items from the `tinny` library, and
use them to define your infrastructure, and commit it to version control. At some
point during development you will need to refer to secrets (for things like private
keys and user passwords). Use the `can` command-line tool to create a Can file which
is a JSON formatted tree sructure of secrets. The secrets in the file can be referred
to by their path throughout your application, and are encrypted with a passphrase.
The Can file may be kept separately from your application, and only brought back
together and decrypted on the computers that need configuring.

You can build your application, run it, and use the integrated web-based user-interface
to browse the infrastructure definitions embedded within it. When you run the
application on one of the computers defined within it, **and** give it the Can file,
you can try to configure the computer. When you do, you will be prompted for the
Can file's passphrase. The secrets used by that computer (or used during configuration
of that computer) are decrypted lazily, and stored/used. After the secrets have
been used they are cleared from memory and the application can be stopped.
