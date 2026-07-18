class AddEmbeddingToModels3d < ActiveRecord::Migration[8.1]
  def change
    enable_extension "vector"

    # 768 dims: gemini-embedding-001 with outputDimensionality=768 (see
    # Search::Embedder) -- pgvector 0.6's hnsw/ivfflat indexes cap at 2000
    # dims, so 768 stays indexable while the native 3072 would not.
    add_column :models3d, :embedding, :vector, limit: 768
    # SHA256 of Model3d#searchable_text at the time the embedding was built —
    # lets the reindex task and the re-embed job skip unchanged models.
    add_column :models3d, :embedding_text_digest, :string

    add_index :models3d, :embedding, using: :hnsw, opclass: :vector_cosine_ops
  end
end
