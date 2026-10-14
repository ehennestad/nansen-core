function writeText(path, text)
%writeText Write text to a file as UTF-8, exactly as given (no line ending conversion)
    arguments
        path (1,1) string
        text
    end
    fid = fopen(path, "w");
    if fid < 0
        error("nansen:io:CannotWrite", "Cannot write %s", path)
    end
    closer = onCleanup(@() fclose(fid));
    fwrite(fid, unicode2native(char(text), "UTF-8"), "uint8");
end
