(in-package #:rag-backend-tsvector/tests)

(defun %chunk (id text &key (document-id "d"))
  (rag-protocol:make-rag-chunk :id id :document-id document-id :text text))

(defun %live-enabled-p ()
  (equal "1" (uiop:getenv "SQL_POSTGRES")))

(defun %connect-keys ()
  (list :host (or (uiop:getenv "SQL_POSTGRES_HOST") "localhost")
        :port (parse-integer (or (uiop:getenv "SQL_POSTGRES_PORT") "5432"))
        :database-name (or (uiop:getenv "SQL_POSTGRES_DB") "postgres")
        :username (or (uiop:getenv "SQL_POSTGRES_USER") "postgres")
        :password (or (uiop:getenv "SQL_POSTGRES_PASSWORD") "postgres")))

(defun %fresh-table ()
  (format nil "rag_fts_~d" (random (expt 10 9))))

(defun %drop-table (store)
  (ignore-errors
    (sql-protocol:execute
     (rag-backend-tsvector:tsvector-store-connection store)
     (format nil "DROP TABLE IF EXISTS ~a"
             (rag-backend-tsvector:tsvector-store-table store)))))

(defun %ensure-postgres-backend ()
  (unless (find-package :sql-backend-postgres)
    (asdf:load-system "sql-backend-postgres")))

(defmacro with-live-store ((store &rest args) &body body)
  `(cond
     ((not (%live-enabled-p))
      (skip "set SQL_POSTGRES=1 to enable live tsvector tests"))
     (t
      (%ensure-postgres-backend)
      (let ((,store (apply #'rag-backend-tsvector:make-tsvector-store
                           :table (%fresh-table)
                           (append (list ,@args) (%connect-keys)))))
        (unwind-protect (progn ,@body)
          (when ,store
            (%drop-table ,store)
            (rag-backend-tsvector:close-tsvector-store ,store)))))))

(deftest invalid-table-name
  (ok (signals (rag-backend-tsvector:make-tsvector-store
                :table "chunks;drop" :ensure-schema nil)
               'rag-protocol:rag-error)))

(deftest invalid-config-name
  (ok (signals (rag-backend-tsvector:make-tsvector-store
                :config "english';drop" :ensure-schema nil)
               'rag-protocol:rag-error)))

(deftest upsert-query-ranks
  (with-live-store (store)
    (rag-protocol:upsert store
                         (list (%chunk "a" "the cat sat on the mat")
                               (%chunk "b" "the cat")))
    (let ((hits (rag-protocol:query-store store "cat mat" :top-k 2)))
      (ok (= 2 (length hits)))
      (ok (equal "a" (rag-protocol:rag-chunk-id
                      (rag-protocol:rag-hit-chunk (first hits)))))
      (ok (> (rag-protocol:rag-hit-score (first hits))
             (rag-protocol:rag-hit-score (second hits)))))))

(deftest replace-and-delete
  (with-live-store (store)
    (rag-protocol:upsert store (%chunk "a" "old token"))
    (rag-protocol:upsert store (%chunk "a" "new token"))
    (let ((hits (rag-protocol:query-store store "new" :top-k 1)))
      (ok (equal "a" (rag-protocol:rag-chunk-id
                      (rag-protocol:rag-hit-chunk (first hits))))))
    (ok (null (rag-protocol:query-store store "old" :top-k 1)))
    (ok (equal '("a") (rag-protocol:delete-ids store "a")))
    (ok (signals (rag-protocol:delete-ids store "a")
                 'rag-protocol:rag-not-found))))

(deftest query-needs-text
  (with-live-store (store)
    (rag-protocol:upsert store (%chunk "a" "alpha"))
    (ok (signals (rag-protocol:query-store store #(1.0 0.0) :top-k 1)
                 'rag-protocol:rag-error))))

(deftest query-filter
  (with-live-store (store)
    (rag-protocol:upsert store
                         (list (%chunk "a" "keep apple")
                               (%chunk "b" "drop apple")))
    (let ((hits (rag-protocol:query-store
                 store "apple" :top-k 5
                 :filter (lambda (ch)
                           (equal "keep apple" (rag-protocol:rag-chunk-text ch))))))
      (ok (= 1 (length hits)))
      (ok (equal "a" (rag-protocol:rag-chunk-id
                      (rag-protocol:rag-hit-chunk (first hits))))))))
