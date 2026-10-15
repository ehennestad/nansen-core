function [ops, stat, Fcell, FcellNeu] = extractSignalsSurroundNeuropil2(ops, stat)
%extractSignalsSurroundNeuropil2 Stub of Suite2P's: ROI k's signal is 10 k + the frame, its neuropil k (ROIs x frames)
    count = numel(stat);
    frames = sum(ops.Nframes);
    Fcell = {single(10 * (1:count)' + (1:frames))};
    FcellNeu = {single(repmat((1:count)', 1, frames))};
end
