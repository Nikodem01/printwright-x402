# Keeps a model's embedding in sync with its searchable text (see
# Model3d#searchable_text). Enqueued by Model3d after title/description/tags
# change; skips the API call when the text digest is already current, and
# degrades quietly (no-op) when embeddings are unavailable — a model without
# an embedding stays searchable and buyable via keyword/trigram.
class EmbedModelJob < ApplicationJob
  queue_as :default

  def perform(model3d_id)
    model = Model3d.find_by(id: model3d_id)
    return unless model

    embedder = Search::Embedder.new
    return unless embedder.available?

    text = model.searchable_text
    digest = Digest::SHA256.hexdigest(text)
    return if model.embedding_text_digest == digest && model.embedding.present?

    vector = embedder.embed(text)
    return if vector.nil?

    model.update!(embedding: vector, embedding_text_digest: digest)
  end
end
