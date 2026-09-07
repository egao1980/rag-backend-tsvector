(in-package #:rag-backend-tsvector)

;;; Postgres FTS store. Stemming / stopwords come from the text-search
;;; config (default english). No embeddings.

(defclass tsvector-store (rag-protocol:rag-vector-store)
  ((connection :initarg :connection :accessor tsvector-store-connection)
   (owns-connection :initarg :owns-connection :accessor tsvector-store-owns-connection
                    :initform nil)
   (table :initarg :table :accessor tsvector-store-table :initform "rag_fts")
   (config :initarg :config :accessor tsvector-store-config :initform "english")))

(defun %table-name (name)
  (let ((s (string name)))
    (unless (and (plusp (length s))
                 (let ((c (char s 0)))
                   (or (alpha-char-p c) (char= c #\_)))
                 (every (lambda (c)
                          (or (alphanumericp c) (char= c #\_)))
                        s))
      (error 'rag-protocol:rag-error
             :message (format nil "invalid table name ~s" name)))
    s))

(defun %config-name (name)
  (let ((s (string-downcase (string name))))
    (unless (and (plusp (length s))
                 (every #'alpha-char-p s))
      (error 'rag-protocol:rag-error
             :message (format nil "invalid text-search config ~s" name)))
    s))

(defun %as-list (x)
  (if (listp x) x (list x)))

(defun %as-single-float (x)
  (etypecase x
    (real (float x 1f0))
    (string
     (float (with-standard-io-syntax
              (let ((*read-eval* nil))
                (read-from-string x)))
            1f0))))

(defun %encode-lisp (value)
  (with-standard-io-syntax
    (let ((*print-readably* t)
          (*print-pretty* nil)
          (*package* (find-package :cl)))
      (prin1-to-string value))))

(defun %decode-lisp (string)
  (when (and string (plusp (length string)))
    (with-standard-io-syntax
      (let ((*read-eval* nil)
            (*package* (find-package :cl)))
        (read-from-string string)))))

(defun %encode-metadata (meta)
  (when meta
    (%encode-lisp meta)))

(defun %decode-metadata (string)
  (%decode-lisp string))

(defun %exec (store sql &optional params)
  (sql-protocol:execute (tsvector-store-connection store) sql params))

(defun %fetch (store sql &optional params)
  (sql-protocol:fetch (%exec store sql params)))

(defun %fetch-all (store sql &optional params)
  (sql-protocol:fetch-all (%exec store sql params)))

(defun ensure-tsvector-schema (store)
  (let ((table (%table-name (tsvector-store-table store)))
        (config (%config-name (tsvector-store-config store))))
    (%exec store
           (format nil
                   "CREATE TABLE IF NOT EXISTS ~a (
  id TEXT PRIMARY KEY,
  document_id TEXT,
  text TEXT NOT NULL,
  metadata TEXT,
  tsv tsvector GENERATED ALWAYS AS (to_tsvector('~a', coalesce(text, ''))) STORED)"
                   table config))
    (%exec store
           (format nil
                   "CREATE INDEX IF NOT EXISTS ~a_tsv_gin ON ~a USING GIN (tsv)"
                   table table))
    store))

(defun %connect-keys (&key host port database-name username password)
  (append (when host (list :host host))
          (when port (list :port (if (integerp port)
                                     port
                                     (parse-integer (princ-to-string port)))))
          (when database-name (list :database-name database-name))
          (when username (list :username username))
          (when password (list :password password))))

(defun make-tsvector-store (&key connection
                                 host
                                 port
                                 database-name
                                 username
                                 password
                                 (table "rag_fts")
                                 (config "english")
                                 (ensure-schema t))
  (let ((table (%table-name table))
        (config (%config-name config)))
    (let* ((owns (null connection))
           (conn (or connection
                     (apply #'sql-protocol:connect
                            :driver :postgres
                            (%connect-keys :host host
                                           :port port
                                           :database-name database-name
                                           :username username
                                           :password password))))
           (store (make-instance 'tsvector-store
                                 :connection conn
                                 :owns-connection owns
                                 :table table
                                 :config config)))
      (when ensure-schema
        (ensure-tsvector-schema store))
      store)))

(defun use-tsvector-store (&rest args &key &allow-other-keys)
  (setf rag-protocol:*rag-store* (apply #'make-tsvector-store args)))

(defun close-tsvector-store (store)
  (when (and (tsvector-store-owns-connection store)
             (tsvector-store-connection store))
    (ignore-errors (sql-protocol:disconnect (tsvector-store-connection store)))
    (setf (tsvector-store-connection store) nil
          (tsvector-store-owns-connection store) nil))
  store)

(defun %chunk-from-row (row)
  (rag-protocol:make-rag-chunk
   :id (getf row :id)
   :document-id (getf row :document_id)
   :text (or (getf row :text) "")
   :metadata (%decode-metadata (getf row :metadata))))

(defun %hit-from-row (row)
  (rag-protocol:make-rag-hit
   :chunk (%chunk-from-row row)
   :score (%as-single-float (or (getf row :score) 0))))

(defmethod rag-protocol:upsert ((store tsvector-store) chunks)
  (let ((table (%table-name (tsvector-store-table store))))
    (sql-protocol:with-transaction ((tsvector-store-connection store))
      (dolist (ch (%as-list chunks))
        (unless (rag-protocol:rag-chunk-id ch)
          (error 'rag-protocol:rag-error :message "chunk id required for upsert"))
        (%exec store
               (format nil
                       "INSERT INTO ~a (id, document_id, text, metadata)
VALUES (?, ?, ?, ?)
ON CONFLICT (id) DO UPDATE SET
  document_id = EXCLUDED.document_id,
  text = EXCLUDED.text,
  metadata = EXCLUDED.metadata"
                       table)
               (list (rag-protocol:rag-chunk-id ch)
                     (rag-protocol:rag-chunk-document-id ch)
                     (or (rag-protocol:rag-chunk-text ch) "")
                     (%encode-metadata (rag-protocol:rag-chunk-metadata ch)))))))
  store)

(defmethod rag-protocol:delete-ids ((store tsvector-store) ids)
  (let* ((table (%table-name (tsvector-store-table store)))
         (ids (%as-list ids))
         (missing '())
         (deleted '()))
    (sql-protocol:with-transaction ((tsvector-store-connection store))
      (dolist (id ids)
        (if (%fetch store (format nil "SELECT id FROM ~a WHERE id = ?" table) (list id))
            (progn
              (%exec store (format nil "DELETE FROM ~a WHERE id = ?" table) (list id))
              (push id deleted))
            (push id missing))))
    (setf missing (nreverse missing)
          deleted (nreverse deleted))
    (when missing
      (restart-case
          (error 'rag-protocol:rag-not-found
                 :ids missing
                 :message (format nil "unknown chunk ids: ~s" missing))
        (continue ()
          :report "Skip missing ids"
          (return-from rag-protocol:delete-ids deleted))
        (use-value (value)
          :report "Return a supplied value"
          (return-from rag-protocol:delete-ids value))))
    deleted))

(defmethod rag-protocol:query-store ((store tsvector-store) query &key top-k filter)
  (let* ((text (rag-protocol:query-text query))
         (table (%table-name (tsvector-store-table store)))
         (config (%config-name (tsvector-store-config store)))
         (k (or top-k 5)))
    (unless (and text (plusp (length text)))
      (error 'rag-protocol:rag-error :message "tsvector query needs text"))
    (let ((sql (format nil
                       "SELECT id, document_id, text, metadata,
       ts_rank(tsv, q) AS score
FROM ~a, plainto_tsquery('~a', ?) AS q
WHERE tsv @@ q
ORDER BY score DESC~a"
                       table config
                       (if filter "" " LIMIT ?")))
          (params (if filter (list text) (list text k))))
      (let ((hits (loop for row in (%fetch-all store sql params)
                        for chunk = (%chunk-from-row row)
                        when (or (null filter) (funcall filter chunk))
                          collect (%hit-from-row row))))
        (rag-protocol:rerank (rag-protocol:make-identity-reranker)
                             query hits :top-k k)))))
