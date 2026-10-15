function out = runSuite2p(stack, ops, folder, register, neuropilCoefficient, spikes)
%runSuite2p Suite2P's MATLAB pipeline (cortex-lab/Suite2P) on a stack, as its run_pipeline and add_deconvolution
%
%   out = runSuite2p(stack, ops, folder, register, neuropilCoefficient, spikes)
%   runs Suite2P on the stack (height x width x frames), whose frames
%   input.tif in the folder holds, with Suite2P's options ops (ops0 of its
%   master file). With register, reg2P registers the frames into Suite2P's
%   binary file; else the binary is written from the stack as reg2P writes
%   it (its own path without registration leaves the binary without
%   frames). Then, as run_pipeline: sourcery finds the cells,
%   extractSignalsSurroundNeuropil2 their signals and surround neuropil, and
%   classifyROI tells cells by its clustrules. Suite2P's results file
%   (F_nansen_suite2p_plane1.mat: ops, stat, Fcell, FcellNeu) is kept in the
%   folder and the binary deleted (DeleteBin). With spikes, wrapperDECONV
%   (OASIS: oasisAR1, of CaImAn-MATLAB or OASIS_matlab) deconvolves each
%   signal less neuropilCoefficient times its neuropil.
%
%   out.pixels holds each ROI's 1-based [row, column] pixels in the frame
%   (Suite2P's stat has them in the registered range, yrange x xrange),
%   out.iscell Suite2P's classification, and out.F, out.Fneu and
%   out.spikes are frames x ROIs, in the stack's values (Suite2P's binary
%   is int16, halved when the stack goes above 2^15, as reg2P's scaleTiff).
%   Written with char and plain functions only, so that it also runs in
%   Octave, where it was tried against Suite2P.
    [height, width, frames] = size(stack);
    scale = 1;
    if max(double(stack(:))) > 2^15
        scale = 2;
    end
    ops.scaleTiff = scale;
    ops.ResultsSavePath = folder;
    ops.RegFileRoot = folder;
    db = struct('mouse_name', 'nansen', 'date', 'suite2p', 'expts', [], 'RootDir', folder);
    ops = feval('build_ops3', db, ops);   % fsroot: the folder's TIFF file, input.tif
    ops.ResultsSavePath = folder;   % not the subfolders build_ops3 makes of mouse_name and date
    if register
        % Suite2P's frame count of a TIFF file, which newer libtiff breaks, replaced while it registers
        compat = fullfile(fileparts(fileparts(fileparts(mfilename('fullpath')))), 'suite2pcompat');
        addpath(compat, '-begin');
        restorePath = onCleanup(@() rmpath(compat));
        ops1 = feval('reg2P', ops);
        clear restorePath
        ops = feval('opsChanges', ops1{1}, ops);   % as run_pipeline: its own settings over reg2P's
    else
        ops.RegFile = fullfile(folder, 'nansen_suite2p_plane1.bin');
        fid = fopen(ops.RegFile, 'w');
        total = zeros(height, width);
        for t = 1:frames
            frame = int16(double(stack(:, :, t)) / scale);
            fwrite(fid, frame, 'int16');
            total = total + double(frame);
        end
        fclose(fid);
        ops.Ly = height;
        ops.Lx = width;
        ops.Nframes = frames;
        ops.mimg1 = total / frames;
        ops.mimg = ops.mimg1;
        ops.yrange = 1:height;
        ops.xrange = 1:width;
        ops.badframes = false(1, frames);
    end
    ops.iplane = 1;
    [ops, stat] = feval('sourcery', ops);
    if isempty(stat)   % no cells: nothing to extract
        stat = struct('ypix', {}, 'xpix', {}, 'iscell', {});
        Fcell = {zeros(0, frames, 'single')};
        FcellNeu = Fcell;
    else
        [ops, stat, Fcell, FcellNeu] = feval('extractSignalsSurroundNeuropil2', ops, stat);
        stat = feval('classifyROI', stat, ops.clustrules);
    end
    save(fullfile(folder, 'F_nansen_suite2p_plane1.mat'), 'ops', 'stat', 'Fcell', 'FcellNeu');
    if exist(ops.RegFile, 'file') == 2
        delete(ops.RegFile);
    end
    count = numel(stat);
    out = struct();
    out.pixels = cell(1, count);
    out.iscell = false(1, count);
    for k = 1:count
        rows = ops.yrange(stat(k).ypix(:));
        columns = ops.xrange(stat(k).xpix(:));
        out.pixels{k} = [rows(:), columns(:)];
        out.iscell(k) = logical(stat(k).iscell);
    end
    out.F = double(Fcell{1})' * scale;
    out.Fneu = double(FcellNeu{1})' * scale;
    out.spikes = zeros(frames, 0);
    if spikes && count > 0
        settings = ops;
        settings.fs = ops.imageRate / ops.nplanes;
        settings.deconvType = 'OASIS';
        settings.estimateNeuropil = 0;
        out.spikes = double(feval('wrapperDECONV', settings, out.F - neuropilCoefficient * out.Fneu));
    end
end
