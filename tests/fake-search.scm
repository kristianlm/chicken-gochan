;; // see https://talks.golang.org/2012/concurrency.slide#50
;; 
;; func fakeSearch(kind string) Search {
;;         return func(query string) Result {
;;               time.Sleep(time.Duration(rand.Intn(100)) * time.Millisecond)
;;               return Result(fmt.Sprintf("%s result for %q\n", kind, query))
;;         }
;; }
;; 
;; func First(query string, replicas ...Search) Result {
;;     c := make(chan Result)
;;     searchReplica := func(i int) { c <- replicas[i](query) }
;;     for i := range replicas {
;;         go searchReplica(i)
;;     }
;;     return <-c
;; }
;; 
;; c := make(chan Result)
;;     go func() { c <- First(query, Web1, Web2) } ()
;;     go func() { c <- First(query, Image1, Image2) } ()
;;     go func() { c <- First(query, Video1, Video2) } ()
;;     timeout := time.After(80 * time.Millisecond)
;;     for i := 0; i < 3; i++ {
;;         select {
;;         case result := <-c:
;;             results = append(results, result)
;;         case <-timeout:
;;             fmt.Println("timed out")
;;             return
;;         }
;;     }
;;     return

(import gochan)

(define (fakeSearch q replica)
  (thread-sleep! (/ (random 100) 1000))
  `(fakeResult for ,q by ,replica))

(define (First query . replicas)
  (define r (gochan 0))
  (for-each (lambda (replica) (go (gochan-send r (fakeSearch query replica))))
	    replicas)
  (gochan-recv r))

(define query "who?")
(define c (gochan 0))

(go (gochan-send c (First query 'web1   'web2)))
(go (gochan-send c (First query 'image1 'image2)))
(go (gochan-send c (First query 'video1 'video2)))

(define start   (current-milliseconds))
(define timeout (gochan-after 80))

(define results
  (let loop ((results '()))
    (if (< (length results) 3)
	(begin
	  (gochan-select
	   ((c -> result)  (loop (cons result results)))
	   ((timeout -> _) (print "timed out") results)))
	results)))

(print "results: ")
(pp results)
(print "elapsed: " (- (current-milliseconds) start))
