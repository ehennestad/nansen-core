function result = labDownloadFile(file, options, context)
%labDownloadFile A file method, as NANSEN dev's project filemethod.downloadFile: on the file viewer's menu of every
%file, for empty files (its files: empty)
%
%   Fetch a file that is only a placeholder here (an empty file) from the
%   archive, which is laid out as the file's root (dev's
%   downloadFile(filePath, rootPath)); a file that is here already is left
%   as it is.
    path = string(file.path);
    root = string(file.root);
    [~, stem, extension] = fileparts(path);
    info = dir(path);
    if info.bytes > 0
        context.log(stem + extension + " is here already");
        result = struct("downloaded", false, "bytes", info.bytes);
        return
    end
    relative = extractAfter(path, strlength(root) + 1);   % after the root and its separator
    copyfile(fullfile(string(options.archive), relative), path);
    info = dir(path);
    context.log("downloaded " + stem + extension);
    result = struct("downloaded", true, "bytes", info.bytes);
end
