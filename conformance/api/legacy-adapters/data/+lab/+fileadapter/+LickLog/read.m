function data = read(filename)
%READ Lick times, one per line.
    data = sscanf(fileread(filename), '%f');
end
