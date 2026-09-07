(defpackage #:rag-backend-tsvector
  (:use #:cl)
  (:export #:tsvector-store
           #:make-tsvector-store
           #:use-tsvector-store
           #:close-tsvector-store
           #:ensure-tsvector-schema
           #:tsvector-store-connection
           #:tsvector-store-table
           #:tsvector-store-config))

(in-package #:rag-backend-tsvector)
