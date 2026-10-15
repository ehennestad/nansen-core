function ops1 = reg2P(ops)
%reg2P Stub of Suite2P's: an empty binary file and a registered range that leaves out the first row and two columns
    info = imfinfo(fullfile(ops.fsroot{1}(1).folder, ops.fsroot{1}(1).name));
    ops.RegFile = fullfile(ops.RegFileRoot, 'stub_plane1.bin');
    fclose(fopen(ops.RegFile, 'w'));
    ops.Ly = info(1).Height;
    ops.Lx = info(1).Width;
    ops.Nframes = numel(info);
    ops.yrange = 2:ops.Ly;
    ops.xrange = 3:ops.Lx;
    ops.mimg = zeros(ops.Ly, ops.Lx);
    ops.mimg1 = ops.mimg;
    ops.badframes = false(1, ops.Nframes);
    ops.registered = true;
    ops1 = {ops};
end
