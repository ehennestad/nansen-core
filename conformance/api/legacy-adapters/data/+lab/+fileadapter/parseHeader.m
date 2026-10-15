function header = parseHeader(text)
%PARSEHEADER The first line of a rig file; not a file adapter.
    header = strtok(text, newline);
end
