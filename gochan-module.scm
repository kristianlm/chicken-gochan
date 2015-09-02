
(module gochan (gochan
                gochan-receive
                gochan-receive*
                gochan-send
                gochan-close

                gochan-closed?

                gochan-for-each
                gochan-fold

                gochan-select
                gochan-select*
                )
(import chicken scheme)
(include "gochan.scm"))
