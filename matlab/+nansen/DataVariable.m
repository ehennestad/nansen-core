classdef DataVariable
%DataVariable A named piece of an entity's data: where its file is, and which adapter reads it
%
%   See schema/data-variable.schema.json.

    properties (SetAccess = private)
        Document (1,1) struct
        Name (1,1) string
        EntityType (1,1) string
        DataLocation (1,1) string
        FilePattern (1,1) string = ""
        FileName (1,1) string = ""
        Subfolder (1,1) string = ""
        FileAdapter (1,1) string
    end

    methods
        function obj = DataVariable(document)
            arguments
                document (1,1) struct
            end
            field = @(name) string(nansen.internal.getField(document, name, ""));
            obj.Document = document;
            obj.Name = field("name");
            obj.EntityType = field("entityType");
            obj.DataLocation = field("dataLocation");
            obj.FilePattern = field("filePattern");
            obj.FileName = field("fileName");
            obj.Subfolder = field("subfolder");
            obj.FileAdapter = field("fileAdapter");
        end

        function relative = relativeFile(obj, values)
            %relativeFile subfolder/fileName with the tokens filled, relative to the entity's folder
            if obj.FileName == ""
                nansen.internal.throwError("no-file-name", ...
                    "data variable '%s' has no fileName, so it cannot be written", obj.Name)
            end
            relative = nansen.internal.fillTemplate(obj.FileName, values, obj.Name);
            if obj.Subfolder ~= ""
                relative = obj.Subfolder + "/" + relative;
            end
        end
    end
end
