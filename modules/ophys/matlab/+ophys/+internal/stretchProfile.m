function [displacement, zoom] = stretchProfile(width, zoom)
%stretchProfile dev's displacement of each column of a SciScan line of width pixels at the zoom factor, as Python's stretch_profile
%
%   The resonant scanner's stretch of dev's SciScan rig, measured on a
%   microgrid (calibration/sciscan_stretch.json): that zoom's profile, or
%   else the nearest zoom's (of two, the smaller), and its zoom.
    root = fileparts(fileparts(fileparts(fileparts(mfilename("fullpath")))));
    data = jsondecode(nansen.internal.readText(fullfile(root, "calibration", "sciscan_stretch.json")));
    profiles = data.profiles;
    if ~iscell(profiles)
        profiles = num2cell(profiles);
    end
    widths = cellfun(@(p) double(p.width), profiles);
    zooms = cellfun(@(p) double(p.zoom), profiles);
    fits = find(reshape(widths, [], 1) == width);
    if isempty(fits)
        nansen.internal.throwError("invalid-options", "there is no stretch profile for lines of %d pixels, only of %s", ...
            width, jsonencode(unique(widths)))
    end
    candidates = reshape(zooms(fits), [], 1);
    [~, order] = sortrows([abs(candidates - zoom), candidates]);   % the nearest, then the smaller
    best = profiles{fits(order(1))};
    displacement = reshape(double(best.displacement), 1, []);
    zoom = double(best.zoom);
end
