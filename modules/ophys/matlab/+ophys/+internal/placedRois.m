function rois = placedRois(found, every, options)
%placedRois The ROIs of each plane's areas (a cell array per plane of 1-based [row, column] pixels), numbered from 1
%
%   Numbered across the planes, the first plane's first. With every plane,
%   each ROI has its place: its plane (from 1) and the options' channel, as
%   nansen.internal.roisAt reads them. As Python's _placed_rois.
    rois = {};
    for p = 1:numel(found)
        for i = 1:numel(found{p})
            roi = ophys.internal.makeRoi(numel(rois) + 1, found{p}{i});
            if every
                roi.plane = p;
                roi.channel = double(nansen.internal.getField(options, "channel", 1));
            end
            rois{end + 1} = roi; %#ok<AGROW>
        end
    end
end
