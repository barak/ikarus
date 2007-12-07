;;; Ikarus Scheme -- A compiler for R6RS Scheme.
;;; Copyright (C) 2006,2007  Abdulaziz Ghuloum
;;; 
;;; This program is free software: you can redistribute it and/or modify
;;; it under the terms of the GNU General Public License version 3 as
;;; published by the Free Software Foundation.
;;; 
;;; This program is distributed in the hope that it will be useful, but
;;; WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;;; General Public License for more details.
;;; 
;;; You should have received a copy of the GNU General Public License
;;; along with this program.  If not, see <http://www.gnu.org/licenses/>.


(library (ikarus system time-and-date)
  (export current-time time? time-second time-nanosecond)
  (import 
    (except (ikarus) time current-time time? time-second
            time-nanosecond))

  (define-struct time (msecs secs usecs))
                  ;;; mega/seconds/micros

  (define (current-time) 
    (foreign-call "ikrt_current_time" (make-time 0 0 0)))

  (define (time-second x)
    (if (time? x) 
        (+ (* (time-msecs x) #e10e6)
           (time-secs x))
        (error 'time-second "not a time" x)))
  
  (define (time-nanosecond x)
    (if (time? x) 
        (* (time-usecs x) 1000)
        (error 'time-nanosecond "not a time" x)))

  )
