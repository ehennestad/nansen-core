function result = labFileSize(file, options, context) %#ok<INUSD>
%labFileSize A file method for some files only: .bin and .dat files with something in them (its files)
%
%   The file's size in bytes.
    info = dir(string(file.path));
    result = struct("bytes", info.bytes);
end
