# chicken-gochan

 [Chicken Scheme]: http://call-cc.org/
 [Go]: http://golang.org/
 [core.async]: https://github.com/clojure/core.async

[Go]-inspired channels for [Chicken Scheme]. Essentially thread-safe
fifo queues that are useful for thread communication and
synchronization.

## Dependencies

- [matchable](wiki.call-cc.org/eggref/4/matchable)

## Development Status

Currently supported:

- receive and send switch (`gochan-select`)
- buffered channels
- timeouts as ordinary receive on a channel
- closable channels
- load-balancing when multiple channels have data ready

## Comparison to real Go Channels

The API and behaviour largely follows [Go]'s channel API, with some
exceptions:

- channels don't have any type information
- sending to a channel that gets closed does not panic, it unblocks
  all senders immediately with the `ok` flag set to `#f`.
- closing an already closed channel has no effect, and is not an error
  (`gochan-close` is idempotent).
- `nil`-channels aren't supported, create new forever-blocking `(gochan 0)` instead.
- Unlike in [Go], you can choose what channels to select on at runtime with `gochan-select*`
  
## Comparison to [core.async]

Honestly, I wish I had stolen the [core.async] API instead of the [Go] channel API 
since that's already a LISP, but here is what we have for now:

- `alt!` is `gochan-select`
- `alts!` is `gochan-select*`
- `<!` is `gochan-recv`
- `>!` is `gochan-send`
- There is no distinction between `park` and `block` because CHICKEN 
  doesn't have native threads.
- The operations don't need to be called inside `(go ...)` blocks.

## API

    [procedure] (gochan capacity)

Construct a channel with a maximum buffer-size of `capacity`. If
`capacity` is `0`, the channel is unbuffered and all its operations
will block until a remote end sends/receives.

    [procedure] (gochan-select ((chan <-|-> msg [ ok ]) body ...) ... [(else body ...])

This is a channel switch that will send or receive on a single
channel, picking whichever clause is able to complete soonest. If no
clause is ready, `gochan-select` will block until one does, unless
`else` is specified which will by execute its body instead of
blocking. Multiple send and receive clauses can be specified
interchangeably. Note that only one clause will be served.

Here's an example:

```scheme
(gochan-select
  ((chan1 -> msg ok) (if ok (print "chan1 says " msg) (print "chan1 closed!")))
  ((chan2 -> msg ok) (if ok (print "chan2 says " msg) (print "chan2 closed!"))))
```

Receive clauses, `((chan -> msg [ok]) body ...)`, execute `body` with
`msg` bound to the message object and `ok` bound to a flag indicating
success. Receiving from a closed immediately completes with the `ok`
flag set to `#f`.

Send clauses, `((chan <- msg [ok]) body ...)`, execute `body` after
`msg` has been sent to a receiver, successfully buffered onto the
channel, or if channel was closed. Sending to a closed channel
immediately completes with the `ok` flag set to `#f`.

A send or receive clause on a closed channel with no `ok` binding
specified will immediately return `(void)` without executing
`body`. This can be combined with recursion like this:

```scheme
;; loop forever until either chan1 or chan2 closes
(let loop ()
   (gochan-select
    ((chan1 -> msg) (print "chan1 says " msg) (loop))
    ((chan2 <- 123) (print "chan2 got  " 123) (loop))))
```

Or like this:

```scheme
;; loop forever until chan1 closes
(let loop ((chan2 chan2))
  (gochan-select
    ((chan1 -> msg)    (print "chan1 says " msg) (loop chan2))
    ((chan2 -> msg ok) (cond (ok (print "chan2 says " msg) (loop chan2))
                             (else (print "chan2 closed, keep going")
                                   ;; replace chan2 with new forever-blocking channel:
                                   (loop (gochan 0)))))))
```

`gochan-select` returns the return-value of the executed clause's
body.

    [procedure] (gochan-send chan msg)

This is short for `(gochan-select ((chan <- msg)))`.

    [procedure] (gochan-recv chan)

This is short for `(gochan-select ((chan -> msg) msg))`.

    [procedure] (gochan-close chan)

Close the channel. Sending to or receiving from a closed channel will
immediately return a `#f` message with the `ok` flag set to `#f`. Note
that this will unblock existing receivers and senders waiting for an
operation on `chan`.

    [procedure] (gochan-after duration/ms)

Return a `gochan` that will "send" a single message after
`duration/ms` milliseconds of its creation. The message is the
`(current-milliseconds)` value at the time of the timeout (not when
the message was received). Receiving more than once on an
`gochan-after` channel will block indefinitely or deadlock the second
time.

```scheme
(gochan-select
 ((chan1 -> msg)                (print "chan1 says " msg))
 (((gochan-after 1000) -> when) (print "chan1 took too long")))
```

You cannot send to or close a timer channel. These are special records
that contain information about when the next timer will
trigger. Creating timers is a relatively cheap operation, and
unlike [golang.time.After](https://golang.org/pkg/time/#After), may be
garbage-collected before the timer triggers. Creating a timer does not
spawn a new thread.

    [procedure] (gochan-tick duration/ms)

Return a `gochan` that will "send" a message every `duration/ms`
milliseconds. The message is the `(current-milliseconds)`
value at the time of the tick (not when it was received).

See [`tests/worker-pool.scm`](tests/worker-pool.scm) for
an example of its use.

    [procedure] (go body ...)

Starts and returns a new srfi-18 thread. Short for `(thread-start!
(lambda () body ...))`.

## Samples

- See [`tests/worker-pool.scm`](tests/worker-pool.scm) for a port of
  [this Go example](https://gobyexample.com/worker-pools).
- See [`tests/secret.scm`](tests/secret.scm) for a port of
  [this](https://blog.jayway.com/2014/09/16/comparing-core-async-and-rx-by-example/)
  [core.async]/[rxjs](https://github.com/Reactive-Extensions/RxJS) challenge.


#### TODO

- Perhaps rename the API to [core.async]'s?
- Add `go-map`, `go-fold` and friends (hopefully simple because we can also do [this](http://clojure.github.io/core.async/#clojure.core.async/map))
- Support customizing buffering behaviour, like [core.async]'s [`dropping-buffer`](http://clojure.github.io/core.async/#clojure.core.async/dropping-buffer) and [`sliding-buffer`](http://clojure.github.io/core.async/#clojure.core.async/sliding-buffer) (harder!)
- Add a priority option to `gochan-select*`?
