function text = readText(path)
%readText Read a UTF-8 file into a char row vector, keeping a byte order mark as U+FEFF
    arguments
        path (1,1) string
    end
    if ~isfile(path)
        nansen.internal.throwError("file-not-found", "File not found: %s", path)
    end
    fid = fopen(path, "r");
    if fid < 0
        nansen.internal.throwError("file-not-found", "Cannot open %s", path)
    end
    closer = onCleanup(@() fclose(fid));
    bytes = fread(fid, Inf, "*uint8")';
    if isempty(bytes)
        text = '';
    else
        text = native2unicode(bytes, "UTF-8");
    end
end
