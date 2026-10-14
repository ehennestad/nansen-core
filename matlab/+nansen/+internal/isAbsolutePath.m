function tf = isAbsolutePath(path)
%isAbsolutePath Whether a path is absolute on any platform: /x, \\server\x or C:\x
    path = char(path);
    tf = ~isempty(path) && (path(1) == '/' || path(1) == '\' || ~isempty(regexp(path, '^[A-Za-z]:[\\/]', 'once')));
end
