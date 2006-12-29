
(let ()
  (define-record stats 
    (user-secs user-usecs sys-secs sys-usecs real-secs real-usecs
     collection-id))

  (define (mk-stats)
    (make-stats #f #f #f #f #f #f #f))

  (define (set-stats! t)
    (foreign-call "ikrt_stats_now" t))

  (define (print-stats message bytes t1 t0)
    (define (print-time msg secs usecs)
      (if (fx< usecs 0)
          (print-time msg (fx- secs 1) (fx+ usecs 1000000))
          (printf "    ~a.~a~a~as ~a time\n"
                  secs
                  (fxremainder (fxquotient usecs 100000) 10)
                  (fxremainder (fxquotient usecs 10000) 10)
                  (fxremainder (fxquotient usecs 1000) 10)
                  msg)))
    (if message
        (printf "running stats for ~a:\n" message)
        (printf "running stats:\n"))
    (let ([collections 
           (fx- (stats-collection-id t1) (stats-collection-id t0))])
      (case collections
        [(0) (display "    no collections\n")]
        [(1) (display "    1 collection\n")]
        [else (printf "    ~a collections\n" collections)]))

    (print-time "user" 
        (fx- (stats-user-secs t1) (stats-user-secs t0))
        (fx- (stats-user-usecs t1) (stats-user-usecs t0)))
    (print-time "system" 
        (fx- (stats-sys-secs t1) (stats-sys-secs t0))
        (fx- (stats-sys-usecs t1) (stats-sys-usecs t0)))
    (print-time "real" 
        (fx- (stats-real-secs t1) (stats-real-secs t0))
        (fx- (stats-real-usecs t1) (stats-real-usecs t0)))
    (printf "    ~a bytes allocated\n" bytes))

  (define time-it
    (case-lambda
      [(proc) 
       (time-it proc #f)]
      [(proc message)
       (unless (procedure? proc)
         (error 'time-it "~s is not a procedure" proc))
       (let* ([t0 (mk-stats)]
              [t1 (mk-stats)]
              [bytes-min (bytes-minor)]
              [bytes-maj (bytes-major)])
         (set-stats! t0)
         (call-with-values proc
           (case-lambda
             [(v)
              (set-stats! t1)
              (print-stats message 
                           (diff-bytes bytes-min bytes-maj 
                              (bytes-minor) (bytes-major))
                           t1 t0)
              v]
             [v*
              (set-stats! t1)
              (print-stats message 
                           (diff-bytes bytes-min bytes-maj 
                              (bytes-minor) (bytes-major))
                           t1 t0)
              (apply values v*)])))]))
                       

  (define (bytes-minor)
    (foreign-call "ikrt_bytes_allocated"))
  (define (bytes-major)
    (foreign-call "ikrt_bytes_allocated_major"))
  (define (diff-bytes mnr0 mjr0 mnr1 mjr1)
    (+ (fx- mnr1 mnr0) (* (fx- mjr1 mjr0) #x10000000)))

  (primitive-set! 'time-it time-it)

)