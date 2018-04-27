;; based on this deadlocking go program:
;;
;; package main
;; import (
;;  "fmt"
;;  "time"
;; )
;;
;; func main() {
;; 	 c := time.After(1 * time.Second);
;; 	 d := make(chan int);
;;
;; 	 go func() { fmt.Printf("go1 %d\n", <-c); d<- 0}()
;; 	 go func() { fmt.Printf("go2 %d\n", <-c); d<- 0}()
;; 	 go func() { fmt.Printf("go3 %d\n", <-c); d<- 0}()
;;
;; 	 <-d; <-d; <-d;
;; }

(import gochan)

(define chan (gochan-after 1000))

(print "starting")

(define t1 (go (print "chan1 says " (gochan-recv chan))))
(define t2 (go (print "chan2 says " (gochan-recv chan))))

(thread-yield!)
(thread-join! t1)
(thread-join! t2)
(print "exiting")
