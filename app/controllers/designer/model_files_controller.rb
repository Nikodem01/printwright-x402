class Designer::ModelFilesController < Designer::BaseController
  def destroy
    Models::FileManager.destroy!(model: model, file: file)
    redirect_to edit_designer_model_path(model, anchor: file_anchor), notice: "File removed."
  rescue Models::FileManager::Error => error
    redirect_to edit_designer_model_path(model, anchor: file_anchor), alert: error.message
  end

  def move
    Models::FileManager.move!(model: model, file: file, direction: params[:direction])
    redirect_to edit_designer_model_path(model, anchor: file_anchor), notice: "File order updated."
  rescue Models::FileManager::Error => error
    redirect_to edit_designer_model_path(model, anchor: file_anchor), alert: error.message
  end

  def feature
    Models::FileManager.feature!(model: model, file: file)
    redirect_to edit_designer_model_path(model, anchor: "images"), notice: "Featured render updated."
  rescue Models::FileManager::Error => error
    redirect_to edit_designer_model_path(model, anchor: "images"), alert: error.message
  end

  private

  def model
    @model ||= current_designer.models3d.find(params[:model_id])
  end

  def file
    @file ||= model.model_files.find(params[:id])
  end

  def file_anchor
    file.kind == "render" ? "images" : "files"
  end
end
