function ops = suite2pOps(options, frames, useGpu)
%suite2pOps Suite2P's (MATLAB) options, ops0 of its master_file_example, with ophys.suite2p's options under Suite2P's names
%
%   The method's options as the MATLAB Suite2P names them: framesPerSecond
%   is imageRate, cellDiameter diameter (and its clustrules' diameter, as
%   run_pipeline sets), tau sensorTau, registration doRegistration,
%   nonrigid nonrigid, thresholdScaling ThScaling, maxIterations
%   maxIterRoiDetection, innerNeuropilRadius innerNeuropil and
%   minNeuropilPixels minNeuropilPixels. sparseMode, spatialScale and
%   denoise are suite2p's (Python) sparse detection, which the MATLAB
%   Suite2P does not have (its detection is sourcery). Everything else is
%   the master file's, without figures, the frames registered first taken
%   from the stack (NimgFirstRegistration: at most 500, and fewer than its
%   frames, as GetRandFrames reads them after the first). Char only, so
%   that it also runs in Octave.
    ops = struct();
    ops.useGPU = double(logical(useGpu));
    ops.fig = 0;
    ops.readTiffHeader = 0;
    ops.temp_tiff = [];
    ops.DeleteBin = 1;
    ops.RegFileTiffLocation = [];
    % registration
    ops.doRegistration = double(logical(options.registration));
    ops.showTargetRegistration = 0;
    ops.PhaseCorrelation = 1;
    ops.SubPixel = Inf;
    ops.NimgFirstRegistration = max(1, min(500, frames - 1));
    ops.nimgbegend = 0;
    ops.dobidi = 1;
    ops.nonrigid = double(logical(options.nonrigid));
    % cell detection
    ops.ShowCellMap = 0;
    ops.sig = 0.5;
    ops.nSVDforROI = 1000;
    ops.NavgFramesSVD = 5000;
    ops.signalExtraction = 'surround';
    ops.refine = 1;
    ops.diameter = double(options.cellDiameter);
    ops.ThScaling = double(options.thresholdScaling);
    ops.maxIterRoiDetection = double(options.maxIterations);
    ops.clustrules = feval('get_clustrules', struct('diameter', ops.diameter));
    ops.splitROIs = 1;
    ops.getROIs = 1;
    % neuropil, in the surround
    ops.innerNeuropil = double(options.innerNeuropilRadius);
    ops.outerNeuropil = Inf;
    ops.minNeuropilPixels = double(options.minNeuropilPixels);
    ops.ratioNeuropil = 5;
    % deconvolution
    ops.imageRate = double(options.framesPerSecond);
    ops.sensorTau = double(options.tau);
    ops.maxNeurop = 1;
    ops.nplanes = 1;
    ops.nchannels = 1;
end
