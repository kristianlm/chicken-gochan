# chicken-gochan

 [Chicken Scheme]: http://call-cc.org/

Go-inspired channels for [Chicken Scheme]. Essentially thread-safe
fifo queues that are useful in concurrency and for thread
synchronization. This implementation has largely been inspired by
[this Go channel tutorial](https://gobyexample.com/channels).

## Requirements

- [srfi-18](http://api.call-cc.org/doc/srfi-18)

## Development Status

Currently supported:

- closable channels (they can have limited length)
- receive from multiple channels `(gochan-receive (list channel1 channel2))`
- `gochan-select` syntax

## Samples

See `./tests/worker-pool.scm` for a port of
[this Go example](https://gobyexample.com/worker-pools).
