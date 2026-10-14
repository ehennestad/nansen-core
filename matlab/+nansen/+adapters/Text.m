classdef Text < nansen.FileAdapter
%Text A UTF-8 text file as a string
    methods
        function data = read(~, path)
            data = string(nansen.internal.readText(path));
        end

        function write(~, path, data)
            nansen.internal.writeText(path, char(string(data)));
        end
    end
end
