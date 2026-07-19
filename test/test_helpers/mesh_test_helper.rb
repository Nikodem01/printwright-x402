module MeshTestHelper
  def box_stl(width: 10.0, depth: 10.0, height: 10.0, offset: [ 0.0, 0.0, 0.0 ], reverse: false)
    x, y, z = offset
    vertices = [
      [ x, y, z ], [ x + width, y, z ], [ x + width, y + depth, z ], [ x, y + depth, z ],
      [ x, y, z + height ], [ x + width, y, z + height ],
      [ x + width, y + depth, z + height ], [ x, y + depth, z + height ]
    ]
    faces = [
      [ 0, 2, 1 ], [ 0, 3, 2 ], [ 4, 5, 6 ], [ 4, 6, 7 ],
      [ 0, 1, 5 ], [ 0, 5, 4 ], [ 1, 2, 6 ], [ 1, 6, 5 ],
      [ 2, 3, 7 ], [ 2, 7, 6 ], [ 3, 0, 4 ], [ 3, 4, 7 ]
    ]
    faces.reverse! if reverse

    [ "solid box", *faces.flat_map do |face|
      [ "facet normal 0 0 0", "outer loop",
       *face.map { |index| "vertex #{vertices[index].join(' ')}" },
       "endloop", "endfacet" ]
    end, "endsolid box" ].join("\n")
  end

  def attach_stl(model, bytes, filename: "box.stl")
    file = model.model_files.create!(kind: "stl", position: model.model_files.count)
    file.file.attach(io: StringIO.new(bytes), filename: filename, content_type: "model/stl")
    file
  end
end
