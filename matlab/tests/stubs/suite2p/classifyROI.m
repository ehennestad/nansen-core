function stat = classifyROI(stat, clustrules)
%classifyROI Stub of Suite2P's: the first ROI is a cell, the others are not
    assert(isfield(clustrules, "diameter"), "no clustrules")
    for k = 1:numel(stat)
        stat(k).iscell = k == 1;
    end
end
