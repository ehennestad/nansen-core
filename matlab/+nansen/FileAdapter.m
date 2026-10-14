classdef (Abstract) FileAdapter
%FileAdapter Reads a file into a value and writes a value to a file
%
%   Subclass it and implement read(obj, path) and write(obj, path, data).
%   Declare the class in a nansen.fileAdapter document to use it in a
%   project.

    methods (Abstract)
        data = read(obj, path)
        write(obj, path, data)
    end
end
