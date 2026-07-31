module Uploads
  # Disk is the one resource this deployment does not own alone: the uploads
  # volume shares a filesystem with the rest of the host. Signup is open, so an
  # unbounded uploader is a denial-of-service against the *machine*, not just
  # against Printwright — every write on the box starts failing when the disk
  # fills, including a neighbouring site's.
  #
  # This is not artificial scarcity (product invariant 2). Nothing here caps
  # what a BUYER may buy: a paid file is delivered as many times as it is asked
  # for, forever, and no counter rations it. These bound only what one account
  # may *store*, which costs real, measured bytes on a real, finite disk.
  #
  # Every limit is derived from that measurement — the volume the deploy
  # provisions — and set high enough that no genuine designer reaches it.
  # Without them, one account uploading 50 MB files in a loop fills the volume
  # in a few hundred requests.
  class Quota
    class << self
      # => nil when the upload fits, else a designer-readable reason.
      # Reasons join the same rejection list as content validation, so a
      # designer who hits a cap gets a normal "Rejected: …" message and keeps
      # whatever else in the same submission was fine — never a 500, and never
      # a silent partial write.
      def reason_to_reject(model:, upload_bytes:)
        file_count_reason(model) ||
          designer_bytes_reason(model.designer, upload_bytes) ||
          global_bytes_reason(upload_bytes)
      end

      # Checked when a model is created rather than when files are attached,
      # because the row itself is the thing being rationed here.
      def reason_to_refuse_new_model(designer)
        limit = config.max_models_per_designer
        return nil if designer.models3d.count < limit

        "You have reached the limit of #{limit} models for one account. " \
          "Delete a draft you no longer need, or ask an operator to raise it."
      end

      def designer_bytes(designer)
        blob_bytes.where(models3d: { designer_id: designer.id }).sum(:byte_size)
      end

      def global_bytes
        ActiveStorage::Blob.sum(:byte_size)
      end

      private

      def file_count_reason(model)
        limit = config.max_files_per_model
        return nil if model.model_files.count < limit

        "this model already has the maximum of #{limit} files"
      end

      def designer_bytes_reason(designer, upload_bytes)
        limit = config.storage_bytes_per_designer
        return nil if designer_bytes(designer) + upload_bytes <= limit

        "your account would go over its #{megabytes(limit)} MB storage allowance — " \
          "delete a file you no longer publish, or ask an operator to raise it"
      end

      # The last line of defence, and the one that protects the host rather
      # than any single account. It is deliberately checked last: a designer
      # should be told they personally are over quota before being told the
      # whole deployment is full.
      def global_bytes_reason(upload_bytes)
        limit = config.storage_bytes_global
        return nil if global_bytes + upload_bytes <= limit

        "this demo deployment has reached its total storage limit — " \
          "uploads are paused until an operator frees space"
      end

      # Joined by hand rather than through the association chain: Active
      # Storage attachments are polymorphic, so there is no association to walk
      # from a designer to their blobs, and summing in Ruby would load every
      # blob row to add up one integer column.
      def blob_bytes
        ActiveStorage::Blob
          .joins("INNER JOIN active_storage_attachments asa ON asa.blob_id = active_storage_blobs.id")
          .joins("INNER JOIN model_files mf ON mf.id = asa.record_id AND asa.record_type = 'ModelFile'")
          .joins("INNER JOIN models3d ON models3d.id = mf.model3d_id")
      end

      def megabytes(bytes) = bytes / 1.megabyte

      def config = Rails.configuration.x.printwright
    end
  end
end
