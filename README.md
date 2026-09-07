# rag-backend-tsvector

Postgres **`tsvector` / `ts_rank`** store for [`rag-protocol`](https://github.com/egao1980/rag-protocol). Stemming and stopwords come from the text-search config (default `english`). No embeddings.

```lisp
(asdf:load-system "sql-backend-postgres")
(asdf:load-system "rag-backend-tsvector")

(let ((store (rag-backend-tsvector:make-tsvector-store
              :host "localhost" :database-name "postgres"
              :username "postgres" :password "postgres")))
  (stack-rag:upsert store
                    (stack-rag:make-rag-chunk :id "a" :text "the cat sat on the mat"))
  (stack-rag:query-store store "cat mat" :top-k 5)
  (rag-backend-tsvector:close-tsvector-store store))
```

Generated column + GIN. Table name `[A-Za-z_][A-Za-z0-9_]*`, config `[A-Za-z]+`. `:filter` is a Lisp function — SQL `LIMIT` only when filter is nil.

Can be the `:lexical-store` of `rag-backend-hybrid`.

Part of [cl-stack](https://github.com/egao1980/cl-stack).

## Tests

```bash
ros -e '(asdf:test-system "rag-backend-tsvector")' -q
SQL_POSTGRES=1 ros -e '(asdf:test-system "rag-backend-tsvector")' -q
```

## License

MIT — see [LICENSE](LICENSE).
