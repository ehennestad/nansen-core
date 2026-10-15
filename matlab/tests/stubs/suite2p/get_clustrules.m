function clustrules = get_clustrules(clustrules)
%get_clustrules Stub of Suite2P's: its rules for the diameter given
    clustrules.MinNpix = round(pi / 4 * clustrules.diameter ^ 2 / 2);
    clustrules.MaxNpix = round(pi / 4 * clustrules.diameter ^ 2 * 2);
    clustrules.Compact = 1.1;
end
