function write(filename, data)
%WRITE Lick times, one per line.
    fid = fopen(filename, 'w');
    fprintf(fid, '%g\n', data);
    fclose(fid);
end
