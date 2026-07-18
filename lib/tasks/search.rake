namespace :search do
  desc "(Re)embed the model catalog for semantic search (FORCE=1 to re-embed unchanged models)"
  task reindex: :environment do
    embedder = Search::Embedder.new
    unless embedder.available?
      puts "GOOGLE_GENERATIVE_AI_API_KEY not set -- embeddings unavailable, nothing to do"
      next
    end

    force = ENV["FORCE"].present?
    embedded = skipped = failed = 0

    Model3d.find_each do |model|
      text = model.searchable_text
      digest = Digest::SHA256.hexdigest(text)

      if !force && model.embedding_text_digest == digest && model.embedding.present?
        skipped += 1
        next
      end

      vector = embedder.embed(text)
      if vector.nil?
        failed += 1
        puts "  failed: #{model.slug}"
        next
      end

      model.update!(embedding: vector, embedding_text_digest: digest)
      embedded += 1
    end

    puts "search:reindex -- embedded #{embedded}, skipped #{skipped} (already current), failed #{failed}"
  end
end
