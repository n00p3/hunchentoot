;;; -*- Mode: LISP; Syntax: COMMON-LISP; Package: HUNCHENTOOT; Base: 10 -*-
;;; $Header: /usr/local/cvsrep/hunchentoot/request.lisp,v 1.35 2008/02/13 16:02:18 edi Exp $

;;; Copyright (c) 2004-2008, Dr. Edmund Weitz.  All rights reserved.

;;; Redistribution and use in source and binary forms, with or without
;;; modification, are permitted provided that the following conditions
;;; are met:

;;;   * Redistributions of source code must retain the above copyright
;;;     notice, this list of conditions and the following disclaimer.

;;;   * Redistributions in binary form must reproduce the above
;;;     copyright notice, this list of conditions and the following
;;;     disclaimer in the documentation and/or other materials
;;;     provided with the distribution.

;;; THIS SOFTWARE IS PROVIDED BY THE AUTHOR 'AS IS' AND ANY EXPRESSED
;;; OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
;;; WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
;;; ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
;;; DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
;;; DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE
;;; GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
;;; INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
;;; WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
;;; NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
;;; SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

(in-package :hunchentoot)

(defclass request ()
  ((headers-in :initarg :headers-in
               :documentation "An alist of the incoming headers.")
   (method :initarg :method
           :documentation "The request method as a keyword.")
   (uri :initarg :uri
           :documentation "The request URI as a string.")
   (server-protocol :initarg :server-protocol
                    :documentation "The HTTP protocol as a keyword.")
   (remote-addr :initarg :remote-addr
                :documentation "The IP address of the client that
initiated this request.")
   (remote-port :initarg :remote-port
                :documentation "The TCP port number of the client
socket from which this request originated.")
   (content-stream :initarg :content-stream
                   :reader content-stream
                   :documentation "A stream from which the request
body can be read if there is one.")
   (cookies-in :initform nil
               :documentation "An alist of the cookies sent by the client.")
   (get-parameters :initform nil
                   :documentation "An alist of the GET parameters sent
by the client.")
   (post-parameters :initform nil
                    :documentation "An alist of the POST parameters
sent by the client.")
   (script-name :initform nil
                :documentation "The URI requested by the client without
the query string.")
   (query-string :initform nil
                 :documentation "The query string of this request.")
   (session :initform nil
            :accessor session
            :documentation "The session object associated with this
request.")
   (aux-data :initform nil
             :accessor aux-data
             :documentation "Used to keep a user-modifiable alist with
arbitrary data during the request.")
   (raw-post-data :initform nil
                  :documentation "The raw string sent as the body of a
POST request, populated only if not a multipart/form-data request."))
  (:documentation "Objects of this class hold all the information
about an incoming request.  They are created automatically by
Hunchentoot and can be accessed by the corresponding handler.

You should not mess with the slots of these objects directly, but you
can subclass REQUEST in order to implement your own behaviour.  See
for example the REQUEST-CLASS keyword argument of START-SERVER and the
function DISPATCH-REQUEST."))

(defun parse-rfc2388-form-data (stream content-type-header)
  "Creates an alist of POST parameters from the stream STREAM which is
supposed to be of content type 'multipart/form-data'."
  (let* ((parsed-content-type-header (rfc2388:parse-header content-type-header :value))
	 (boundary (or (cdr (rfc2388:find-parameter
                             "BOUNDARY"
                             (rfc2388:header-parameters parsed-content-type-header)))
		       (return-from parse-rfc2388-form-data))))
    (loop for part in (rfc2388:parse-mime stream boundary)
          for headers = (rfc2388:mime-part-headers part)
          for content-disposition-header = (rfc2388:find-content-disposition-header headers)
          for name = (cdr (rfc2388:find-parameter
                           "NAME"
                           (rfc2388:header-parameters content-disposition-header)))
          when name
          collect (cons name
                        (let ((contents (rfc2388:mime-part-contents part)))
                          (if (pathnamep contents)
                            (list contents
                                  (rfc2388:get-file-name headers)
                                  (rfc2388:content-type part :as-string t))
                            contents))))))

(defun get-post-data (&key (request *request*) want-stream (already-read 0))
  "Reads the request body from the stream and stores the raw contents
\(as an array of octets) in the corresponding slot of the REQUEST
object.  Returns just the stream if WANT-STREAM is true.  If there's a
Content-Length header, it is assumed, that ALREADY-READ octets have
already been read."
  (let* ((headers-in (headers-in request))
         (content-length (when-let (content-length-header (cdr (assoc :content-length headers-in)))
                           (parse-integer content-length-header :junk-allowed t)))
         (content-stream (content-stream request)))
    (setf (slot-value request 'raw-post-data)
          (cond (want-stream
                 (let ((stream (make-flexi-stream content-stream :external-format +latin-1+)))
                   (when content-length
                     (setf (flexi-stream-bound stream) content-length))
                   stream))
                ((and content-length (> content-length already-read))
                 (decf content-length already-read)
                 (when (input-chunking-p)
                   ;; see RFC 2616, section 4.4
                   (log-message* :warning "Got Content-Length header although input chunking is on."))
                 (let ((content (make-array content-length :element-type 'octet)))
                   (read-sequence content content-stream)
                   content))
                ((input-chunking-p)
                 (loop with buffer = (make-array +buffer-length+ :element-type 'octet)
                       with content = (make-array 0 :element-type 'octet :adjustable t)
                       for index = 0 then (+ index pos)
                       for pos = (read-sequence buffer content-stream)
                       do (adjust-array content (+ index pos))
                          (replace content buffer :start1 index :end2 pos)
                       while (= pos +buffer-length+)
                       finally (return content)))))))

(defmethod initialize-instance :after ((request request) &rest init-args)
  "The only initarg for a REQUEST object is :HEADERS-IN.  All other
slot values are computed in this :AFTER method."
  (declare (ignore init-args))
  (with-slots (headers-in cookies-in get-parameters script-name query-string session)
      request
    (handler-case
        (progn
          (let* ((uri (request-uri request))
                 (match-start (position #\? uri)))
            (cond
             (match-start
              (setq script-name (subseq uri 0 match-start)
                    query-string (subseq uri (1+ match-start))))
             (t (setq script-name uri))))
          ;; some clients (e.g. ASDF-INSTALL) send requests like
          ;; "GET http://server/foo.html HTTP/1.0"...
          (setq script-name (regex-replace "^https?://[^/]+" script-name ""))
          ;; compute GET parameters from query string and cookies from
          ;; the incoming 'Cookie' header
          (setq get-parameters
                (form-url-encoded-list-to-alist (split "&" query-string))
                cookies-in
                (form-url-encoded-list-to-alist (split "\\s*[,;]\\s*" (cdr (assoc :cookie headers-in)))
                                                +utf-8+)
                session (session-verify request)
                *session* session))
      (error (condition)
        (log-message* :error "Error when creating REQUEST object: ~A" condition)
        ;; we assume it's not our fault...
        (setf (return-code) +http-bad-request+)))))

(defun parse-multipart-form-data (&optional (request *request*))
  "Parse the REQUEST body as multipart/form-data, assuming that its
content type has already been verified.  Returns the form data as
alist or NIL if there was no data or the data could not be parsed."
  (handler-case
      (let ((content-stream (make-flexi-stream (content-stream request) :external-format +latin-1+)))
        (prog1
            (parse-rfc2388-form-data content-stream (header-in :content-type))
          (let ((stray-data (get-post-data :already-read (flexi-stream-position content-stream))))
            (when (and stray-data (plusp (length stray-data)))
              (hunchentoot-warn "~A octets of stray data after form-data sent by client."
                                (length stray-data))))))
    (error (condition)
      (log-message* :error "While parsing multipart/form-data parameters: ~A" condition)
      nil)))

(defun maybe-read-post-parameters (&key (request *request*) force external-format)
  "Make surce that any POST parameters in the REQUEST are parsed.  The
body of the request must be either application/x-www-form-urlencoded
or multipart/form-data to be considered as containing POST parameters.
If FORCE is true, parsing is done unconditionally.  Otherwise, parsing
will only be done if the RAW-POST-DATA slot in the REQUEST is false.
EXTERNAL-FORMAT specifies the external format of the data in the
request body.  By default, the encoding is determined from the
Content-Type header of the request or from
*HUNCHENTOOT-DEFAULT-EXTERNAL-FORMAT* if none is found."
  (when (and (header-in :content-type)
             (member (request-method) *methods-for-post-parameters* :test #'eq)
             (or force
                 (not (slot-value request 'raw-post-data))))
    (unless (or (header-in :content-length)
                (input-chunking-p))
      (log-message* :warning "Can't read request body because there's ~
no Content-Length header and input chunking is off.")
      (return-from maybe-read-post-parameters nil))
    (handler-case
        (multiple-value-bind (type subtype charset)
              (parse-content-type (header-in :content-type))
          (let ((external-format (or external-format
                                     (when charset
                                       (handler-case
                                           (make-external-format charset :eol-style :lf)
                                         (error ()
                                           (hunchentoot-warn "Ignoring ~
unknown character set ~A in request content type."
                                                 charset))))
                                     *hunchentoot-default-external-format*)))
            (setf (slot-value request 'post-parameters)
                  (cond ((and (string-equal type "application")
                              (string-equal subtype "x-www-form-urlencoded"))
                         (form-url-encoded-list-to-alist
                          (split "&" (raw-post-data :external-format +latin-1+))
                          external-format))
                        ((and (string-equal type "multipart")
                              (string-equal subtype "form-data"))
                         (prog1 (parse-multipart-form-data request)
                           (setf (slot-value request 'raw-post-data) t)))))))
      (error (condition)
        (log-message* :error "Error when reading POST parameters from body: ~A" condition)
        ;; we assume it's not our fault...
        (setf (return-code) +http-bad-request+)))))

(defun recompute-request-parameters (&key (request *request*)
                                          (external-format *hunchentoot-default-external-format*))
  "Recomputes the GET and POST parameters for the REQUEST object
REQUEST.  This only makes sense if you're switching external formats
during the request."
  (maybe-read-post-parameters :request request :force t :external-format external-format)
  (setf (slot-value request 'get-parameters)
        (form-url-encoded-list-to-alist (split "&" (slot-value request 'query-string)) external-format))
  (values))
                                                
(defun script-name (&optional (request *request*))
  "Returns the file name of the REQUEST object REQUEST. That's the
requested URI without the query string \(i.e the GET parameters)."
  (slot-value request 'script-name))

(defun query-string (&optional (request *request*))
  "Returns the query string of the REQUEST object REQUEST. That's
the part behind the question mark \(i.e. the GET parameters)."
  (slot-value request 'query-string))

(defun get-parameters (&optional (request *request*))
  "Returns an alist of the GET parameters associated with the REQUEST
object REQUEST."
  (slot-value request 'get-parameters))

(defun post-parameters (&optional (request *request*))
  "Returns an alist of the POST parameters associated with the REQUEST
object REQUEST."
  (maybe-read-post-parameters :request request)
  (slot-value request 'post-parameters))

(defun headers-in (&optional (request *request*))
  "Returns an alist of the incoming headers associated with the
REQUEST object REQUEST."
  (slot-value request 'headers-in))

(defun cookies-in (&optional (request *request*))
  "Returns an alist of all cookies associated with the REQUEST object
REQUEST."
  (slot-value request 'cookies-in))

(defun header-in (name &optional (request *request*))
  "Returns the incoming header with name NAME.  NAME can be a keyword
\(recommended) or a string."
  (cdr (assoc name (headers-in request))))

(defun authorization (&optional (request *request*))
  "Returns as two values the user and password \(if any) as encoded in
the 'AUTHORIZATION' header.  Returns NIL if there is no such header."
  (let* ((authorization (header-in :authorization request))
         (start (and authorization
                     (> (length authorization) 5)
                     (string-equal "Basic" authorization :end2 5)
                     (scan "\\S" authorization :start 5))))
    (when start
      (destructuring-bind (&optional user password)
          (split ":" (base64:base64-string-to-string (subseq authorization start)))
        (values user password)))))

(defun remote-addr (&optional (request *request*))
  "Returns the address the current request originated from."
  (slot-value request 'remote-addr))

(defun remote-port (&optional (request *request*))
  "Returns the port the current request originated from."
  (slot-value request 'remote-port))

(defun real-remote-addr (&optional (request *request*))
  "Returns the 'X-Forwarded-For' incoming http header as the
second value in the form of a list of IP addresses and the first
element of this list as the first value if this header exists.
Otherwise returns the value of REMOTE-ADDR as the only value."
  (let ((x-forwarded-for (header-in :x-forwarded-for request)))
    (cond (x-forwarded-for (let ((addresses (split "\\s*,\\s*" x-forwarded-for)))
                             (values (first addresses) addresses)))
          (t (remote-addr request)))))

(defun host (&optional (request *request*))
  "Returns the 'Host' incoming http header value."
  (header-in :host request))

(defun request-uri (&optional (request *request*))
  "Returns the request URI."
  (slot-value request 'uri))

(defun request-method (&optional (request *request*))
  "Returns the request method as a Lisp keyword."
  (slot-value request 'method))

(defun server-protocol (&optional (request *request*))
  "Returns the request protocol as a Lisp keyword."
  (slot-value request 'server-protocol))

(defun user-agent (&optional (request *request*))
  "Returns the 'User-Agent' http header."
  (header-in :user-agent request))

(defun cookie-in (name &optional (request *request*))
  "Returns the cookie with the name NAME \(a string) as sent by the
browser - or NIL if there is none."
  (cdr (assoc name (cookies-in request) :test #'string=)))

(defun referer (&optional (request *request*))
  "Returns the 'Referer' \(sic!) http header."
  (header-in :referer request))

(defun get-parameter (name &optional (request *request*))
  "Returns the GET parameter with name NAME \(a string) - or NIL if
there is none.  Search is case-sensitive."
  (cdr (assoc name (get-parameters request) :test #'string=)))

(defun post-parameter (name &optional (request *request*))
  "Returns the POST parameter with name NAME \(a string) - or NIL if
there is none.  Search is case-sensitive."
  (cdr (assoc name (post-parameters request) :test #'string=)))

(defun parameter (name &optional (request *request*))
  "Returns the GET or the POST parameter with name NAME \(a string) -
or NIL if there is none.  If both a GET and a POST parameter with the
same name exist the GET parameter is returned.  Search is
case-sensitive."
  (or (get-parameter name request)
      (post-parameter name request)))

(defun handle-if-modified-since (time &optional (request *request*))
  "Handles the 'If-Modified-Since' header of REQUEST.  The date string
is compared to the one generated from the supplied universal time
TIME."
  (let ((if-modified-since (header-in :if-modified-since request))
        (time-string (rfc-1123-date time)))
    ;; simple string comparison is sufficient; see RFC 2616 14.25
    (when (and if-modified-since
               (equal if-modified-since time-string))
      (setf (return-code) +http-not-modified+)
      (throw 'handler-done nil))
    (values)))

(defun external-format-from-content-type (content-type)
  "Creates and returns an external format corresponding to the value
of the content type header provided in CONTENT-TYPE.  If the content
type was not set or if the character set specified was invalid, NIL is
returned."
  (when content-type
    (when-let (charset (nth-value 2 (parse-content-type content-type)))
      (handler-case
          (make-external-format (as-keyword charset) :eol-style :lf)
        (error ()
          (hunchentoot-warn "Invalid character set ~S in request has been ignored."
                            charset))))))

(defun raw-post-data (&key (request *request*) external-format force-text force-binary want-stream)
  "Returns the content sent by the client if there was any \(unless
the content type was \"multipart/form-data\").  By default, the result
is a string if the type of the `Content-Type' media type is \"text\",
and a vector of octets otherwise.  In the case of a string, the
external format to be used to decode the content will be determined
from the `charset' parameter sent by the client \(or otherwise
*HUNCHENTOOT-DEFAULT-EXTERNAL-FORMAT* will be used).

You can also provide an external format explicitly \(through
EXTERNAL-FORMAT) in which case the result will unconditionally be a
string.  Likewise, you can provide a true value for FORCE-TEXT which
will force Hunchentoot to act as if the type of the media type had
been \"text\".  Or you can provide a true value for FORCE-BINARY which
means that you want a vector of octets at any rate.

If, however, you provide a true value for WANT-STREAM, the other
parameters are ignored and you'll get the content \(flexi) stream to
read from it yourself.  It is then your responsibility to read the
correct amount of data, because otherwise you won't be able to return
a response to the client.  If the content type of the request was
`multipart/form-data' or `application/x-www-form-urlencoded', the
content has been read by Hunchentoot already and you can't read from
the stream anymore.

You can call RAW-POST-DATA more than once per request, but you can't
mix calls which have different values for WANT-STREAM.

Note that this function is slightly misnamed because a client can send
content even if the request method is not POST."
  (when (and force-binary force-text)
    (parameter-error "It doesn't make sense to set both FORCE-BINARY and FORCE-TEXT to a true value."))
  (unless (or external-format force-binary)
    (setq external-format (or (external-format-from-content-type (header-in :content-type request))
                              (when force-text
                                *hunchentoot-default-external-format*))))
  (let ((raw-post-data (or (slot-value request 'raw-post-data)
                           (get-post-data :request request :want-stream want-stream))))
    (cond ((typep raw-post-data 'stream) raw-post-data)
          ((member raw-post-data '(t nil)) nil)
          (external-format (octets-to-string raw-post-data :external-format external-format))
          (t raw-post-data))))

(defun aux-request-value (symbol &optional (request *request*))
  "Returns the value associated with SYMBOL from the request object
REQUEST \(the default is the current request) if it exists.  The
second return value is true if such a value was found."
  (when request
    (let ((found (assoc symbol (aux-data request))))
      (values (cdr found) found))))

(defsetf aux-request-value (symbol &optional request)
    (new-value)
  "Sets the value associated with SYMBOL from the request object
REQUEST \(default is *REQUEST*).  If there is already a value
associated with SYMBOL it will be replaced."
  (with-rebinding (symbol)
    (with-unique-names (place %request)
      `(let* ((,%request (or ,request *request*))
              (,place (assoc ,symbol (aux-data ,%request))))
         (cond
           (,place
            (setf (cdr ,place) ,new-value))
           (t
            (push (cons ,symbol ,new-value)
                  (aux-data ,%request))
            ,new-value))))))

(defun delete-aux-request-value (symbol &optional (request *request*))
  "Removes the value associated with SYMBOL from the request object
REQUEST."
  (when request
    (setf (aux-data request)
            (delete symbol (aux-data request)
                    :key #'car :test #'eq)))
  (values))