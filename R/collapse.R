#' @title Collapse NHDPlus Network
#' @description Refactors the NHDPlus flowline network, eliminating short and non-cconfluence flowlines.
#' @param flines data.frame with COMID, toCOMID, LENGTHKM, and TotDASqKM columns
#' @param thresh numeric a length threshold (km). Flowlines shorter than this will be eliminated
#' @param add_category boolean if combination category is desired in output, set to TRUE
#' @param mainstem_thresh numeric threshold for combining inter-confluence mainstems
#' @param warn boolean controls whether warning an status messages are printed
#' @return A refactored network with merged up and down flowlines.
#' @importFrom dplyr filter left_join select mutate group_by ungroup summarise distinct
#' @noRd
#'
collapse_flowlines <- function(flines, thresh, add_category = FALSE, mainstem_thresh = NULL, warn = TRUE) {

  # very large thresh
  if (is.null(mainstem_thresh)) {
    mainstem_thresh_use <- max(flines$LENGTHKM)
  } else {
    mainstem_thresh_use <- mainstem_thresh
  }

  original_fline_atts <- flines

  short_outlets_tracker <- c()
  headwaters_tracker <- c()
  removed_mainstem <- data.frame(removed_COMID = c(), stringsAsFactors = FALSE)

  #######################################################
  # Short Outlets
  #######################################################
  # Need to clean up the short outlets first so they don't get broken by the method below.

  flines <- collapse_outlets(flines, thresh, original_fline_atts, warn)

  short_outlets_tracker <- flines[["short_outlets_tracker"]]
  flines <- flines[["flines"]]

  #######################################################
  # Short Headwaters
  #######################################################
  # Next merge headwaters that don't cross confluences downstream

  if (!"joined_toCOMID" %in% names(flines)) flines$joined_toCOMID <- NA
  if (!"joined_fromCOMID" %in% names(flines)) flines$joined_fromCOMID <- NA

  # Clean up short headwaters that aren't handled by the next downstream logic above.
  remove_headwaters <- function(flines) {
    !(flines$COMID %in% flines$toCOMID) & # a headwater (nothing flows to it)
      flines$LENGTHKM < thresh & # shorter than threshold
      is.na(flines$joined_fromCOMID) &
      is.na(flines$joined_toCOMID) &
      !is.na(flines$toCOMID) &
      flines$toCOMID != -9999
  }

  flines <- reconcile_downstream(flines, remove_headwaters, remove_problem_headwaters = TRUE)

  headwaters_tracker <- flines[["removed_tracker"]]
  flines <- flines[["flines"]]

  #######################################################
  # Short Interconfluence Flowpath Top Flowlines
  #######################################################
  # If mainstems are being collapsed at a threshold, these need to be treated seperately
  mainstem_top_tracker <- NULL
  if (!is.null(mainstem_thresh)) {
    flines$num_upstream <- get_num_upstream(flines)
    flines$ds_num_upstream <- get_ds_num_upstream(flines)

    # At the top of a mainstem
    # shorter than mainstem threshold
    # is still in scope
    remove_mainstem_top <- function(flines) {
      (flines$num_upstream > 1 &
         flines$ds_num_upstream == 1) &
        flines$LENGTHKM < mainstem_thresh_use &
        !is.na(flines$toCOMID)
    }

    flines <- reconcile_downstream(flines, remove_mainstem_top, remove_problem_headwaters = FALSE)
    mainstem_top_tracker <- flines[["removed_tracker"]]
    flines <- flines[["flines"]]

    flines <- select(flines, -num_upstream, -ds_num_upstream)
  }

  #######################################################
  # Short Interconfluence Flowpath Flowlines
  #######################################################
  # Combine along main stems with no confluences.

  flines <- mutate(flines,
                   dsLENGTHKM = get_dsLENGTHKM(flines),
                   ds_num_upstream = get_ds_num_upstream(flines))

  reroute_mainstem_set <- (flines$dsLENGTHKM > 0 & # is still in scope
                             is.na(flines$joined_toCOMID) & # wasn't already collapsed as a headwater
                             flines$ds_num_upstream == 1 & # is not upstream of a confluence
                             flines$dsLENGTHKM < mainstem_thresh_use) # is shorter than the mainstem threshold


  # This is the set that is going to get skipped in the rerouting.
  removed_mainstem <- data.frame(removed_COMID = flines[["toCOMID"]][reroute_mainstem_set],
                                 joined_fromCOMID = flines[["COMID"]][reroute_mainstem_set],
                                 stringsAsFactors = FALSE)

  flines <- reconcile_removed_flowlines(flines, reroute_mainstem_set, removed_mainstem, original_fline_atts)

  if (nrow(removed_mainstem) > 0) removed_mainstem$joined_toCOMID <- NA

  if (!is.null(mainstem_thresh) & !is.null(mainstem_top_tracker)) {
    removed_mainstem_top <- left_join(data.frame(removed_COMID = mainstem_top_tracker,
                                                 joined_fromCOMID = NA, stringsAsFactors = FALSE),
                                      select(flines, COMID, joined_toCOMID),
                                      by = c("removed_COMID" = "COMID"))
    removed_mainstem <- rbind(removed_mainstem, removed_mainstem_top)
  }
  #######################################################
  # Short Single Confluence to Confluence Flowpaths
  #######################################################
  # Combine accross confluences next -- slightly different logic from "mainstems"

  flines <- mutate(flines,
                   dsLENGTHKM = get_dsLENGTHKM(flines),
                   ds_num_upstream = get_ds_num_upstream(flines))

  # This is the set that is going to get rerouted removing their next downstream.
  # removes all terminal and already removed flowlines from consideration.
  reroute_confluence_set <- (flines$dsLENGTHKM < thresh &
                               flines$dsLENGTHKM > 0 &
                               flines$ds_num_upstream > 1)

  flines <- select(flines, -ds_num_upstream)

  # This is the set that is going to get skipped in the rerouting.
  removed_confluence <- data.frame(removed_COMID = flines[["toCOMID"]][reroute_confluence_set],
                                   joined_fromCOMID = flines[["COMID"]][reroute_confluence_set],
                                   stringsAsFactors = FALSE)

  # Need to deduplicate the upstream that removed will get combined with.
  removed_confluence <- group_by(left_join(removed_confluence,
                                           select(original_fline_atts, COMID,
                                                  usTotDASqKM = TotDASqKM, # Get upstream area and length
                                                  usLENGTHKM = LENGTHKM), # by joining fromCOMID to COMID
                                           by = c("joined_fromCOMID" = "COMID")),
                                 removed_COMID)
  removed_confluence <- select(ungroup(filter(filter(removed_confluence,
                                                     usTotDASqKM == max(usTotDASqKM)), # Deduplicate by area first
                                              usLENGTHKM == max(usLENGTHKM))), # then length.
                               -usLENGTHKM, -usTotDASqKM) # clean

  flines <- reconcile_removed_flowlines(flines, reroute_confluence_set, removed_confluence, original_fline_atts)

  ####################################
  # Cleanup and prepare output
  ####################################
  # Catchments that joined downstream but are referenced as a joined fromCOMID.
  # These need to be adjusted to be joined_toCOMID the same as the one they reference in joined_fromCOMID.
  potential_bad_rows <- flines$COMID[which(!is.na(flines$joined_toCOMID) & flines$joined_toCOMID != -9999)]
  bad_joined_fromcomid <- potential_bad_rows[potential_bad_rows %in% flines$joined_fromCOMID]

  if (length(bad_joined_fromcomid > 0)) {
    # This is the row we will update
    bad_joined_fromcomid_index <- match(bad_joined_fromcomid, flines$joined_fromCOMID)
    # This is the row we will get our update from
    new_joined_tocomid_index <- match(bad_joined_fromcomid, flines$COMID)
    flines$joined_toCOMID[bad_joined_fromcomid_index] <- flines$joined_toCOMID[new_joined_tocomid_index]
    flines$joined_fromCOMID[bad_joined_fromcomid_index] <- NA
  }

  # And the opposite direction
  potential_bad_rows <- flines$COMID[which(!is.na(flines$joined_fromCOMID) & flines$joined_fromCOMID != -9999)]
  bad_joined_tocomid <- potential_bad_rows[potential_bad_rows %in% flines$joined_toCOMID]

  if (length(bad_joined_tocomid > 0)) {
    # This is the row we will update
    bad_joined_tocomid_index <- match(bad_joined_tocomid, flines$joined_toCOMID)
    # This is the row we will get our update from
    new_joined_fromcomid_index <- match(bad_joined_tocomid, flines$COMID)
    flines$joined_fromCOMID[bad_joined_tocomid_index] <- flines$joined_fromCOMID[new_joined_fromcomid_index]
    flines$joined_toCOMID[bad_joined_tocomid_index] <- NA
  }

  if (add_category) {
    if (!"join_category" %in% names(flines)) {
      flines$join_category <- NA
    }
    flines <- mutate(flines,
                     join_category = ifelse(COMID %in% short_outlets_tracker, "outlet",
                      ifelse(COMID %in% removed_mainstem$removed_COMID, "mainstem",
                       ifelse(COMID %in% removed_confluence$removed_COMID, "confluence",
                         ifelse(COMID %in% headwaters_tracker, "headwater", join_category)))))
  }

  # This takes care of na toCOMIDs that result from join_toCOMID pointers.
  flines <- left_join(flines,
                      select(flines,
                             COMID,
                             new_toCOMID = joined_toCOMID),
                      by = c("toCOMID" = "COMID"))

  flines <- mutate(flines, toCOMID = ifelse(!is.na(new_toCOMID), new_toCOMID, toCOMID))

  flines <- select(flines, -new_toCOMID)

  bad_rows_to <- function(flines) is.na(flines$toCOMID) &
    flines$LENGTHKM == 0 &
    flines$COMID %in% flines$joined_toCOMID &
    flines$joined_toCOMID != -9999

  bad_rows_from <- function(flines) is.na(flines$toCOMID) &
    flines$LENGTHKM == 0 &
    flines$COMID %in% flines$joined_fromCOMID &
    flines$joined_fromCOMID != -9999

  count <- 0

  # Should investigate why NAs are coming out of the splitter.
  while (any(bad_rows_to(flines), na.rm = TRUE) |
         any(bad_rows_from(flines), na.rm = TRUE)) {

    flines <- left_join(flines,
                        select(flines,
                               new_joined_toCOMID = joined_toCOMID,
                               new_joined_fromCOMID = joined_fromCOMID,
                               COMID), by = c("joined_toCOMID" = "COMID"))

    flines <- mutate(flines,
                     joined_toCOMID = ifelse( (!is.na(new_joined_toCOMID) &
                                                 new_joined_toCOMID != -9999),
                                              new_joined_toCOMID,
                                              ifelse( (!is.na(new_joined_fromCOMID) &
                                                         new_joined_fromCOMID != -9999),
                                                      new_joined_fromCOMID,
                                                      joined_toCOMID)))

    flines <- select(flines, -new_joined_toCOMID, -new_joined_fromCOMID)

    flines <- left_join(flines,
                        select(flines,
                               new_joined_toCOMID = joined_toCOMID,
                               new_joined_fromCOMID = joined_fromCOMID,
                               COMID), by = c("joined_fromCOMID" = "COMID"))

    flines <- mutate(flines,
                     joined_fromCOMID = ifelse( (!is.na(new_joined_fromCOMID) &
                                                   new_joined_fromCOMID != -9999),
                                                new_joined_fromCOMID,
                                                ifelse( (!is.na(new_joined_toCOMID) &
                                                           new_joined_toCOMID != -9999),
                                                        new_joined_toCOMID,
                                                        joined_fromCOMID)))

    flines <- select(flines, -new_joined_toCOMID, -new_joined_fromCOMID)

    count <- count + 1
    if (count > 20) {
      stop("stuck in final clean up loop")
    }
  }


  return(distinct(flines))
}

#' @title Collapse Outlets
#' @description Collapses outlet flowlines upstream. Returns an flines dataframe.
#' @param flines data.frame with COMID, toCOMID, LENGTHKM, and TotDASqKM columns
#' @param thresh numeric a length threshold (km). Flowlines shorter than this will be eliminated
#' @param original_fline_atts data.frame containing original fline attributes.
#' @param warn boolean controls whether warning an status messages are printed
#' @return flines data.frame with outlets collapsed to the given threshold.
#' @importFrom dplyr filter left_join select mutate group_by ungroup
#' @noRd
#'
collapse_outlets <- function(flines, thresh, original_fline_atts, warn = TRUE) {

  if (warn & ("joined_toCOMID" %in% names(flines) | "joined_fromCOMID" %in% names(flines))) {
    warning("collapse outllets must be used with un modified flines. \n",
            "returning unmodified flines from collapse outlets. \n")
    return(list(flines = flines, short_outlets_tracker = c()))
  }

  flines$joined_fromCOMID <- NA

  short_outlets <- function(flines) {
    is.na(flines$toCOMID) & # No toCOMID,
      flines$LENGTHKM < thresh & # too short,
      is.na(flines$joined_fromCOMID) # and hasn't been combined yet.
  }

  #######################################################

  count <- 0
  short_outlets_tracker <- c()

  while (any(short_outlets(flines))) {
    short_flines_next <- filter(flines, short_outlets(flines))

    if (!exists("short_flines")) {
      short_flines <- short_flines_next
    } else if (all(short_flines_next$COMID %in% short_flines$COMID)) {
      stop("Stuck in short flines loop")
    } else {
      short_flines <- short_flines_next
    }

    short_flines_index <- which(short_outlets(flines))

    headwaters <- !short_flines$COMID %in% original_fline_atts$toCOMID

    if (any(headwaters)) {
      headwater_COMIDs <- short_flines[["COMID"]][which(headwaters)]
      flines[["joined_fromCOMID"]][match(headwater_COMIDs, flines$COMID)] <- -9999
      short_flines <- short_flines[!headwaters, ]
      short_flines_index <- short_flines_index[!headwaters]
    }

    # Get from length and from area with a join on toCOMID.
    short_flines <- left_join(short_flines,
                              select(original_fline_atts, toCOMID,
                                     fromCOMID = COMID,
                                     fromLENGTHKM = LENGTHKM,
                                     fromTotDASqKM = TotDASqKM),
                              by = c("COMID" = "toCOMID")) %>%
      group_by(COMID) %>%  # deduplicate with area then length.
      filter(is.na(joined_fromCOMID) | joined_fromCOMID != -9999) %>%
      filter(fromTotDASqKM == max(fromTotDASqKM)) %>%
      filter(fromLENGTHKM == max(fromLENGTHKM)) %>%
      filter(fromCOMID == max(fromCOMID)) %>% # This is dumb, but happens if DA and Length are equal...
      ungroup()
    # This is a pointer to the flines rows that need to absorb a downstream short flowline.
    flines_to_update_index <- match(short_flines$fromCOMID, flines$COMID)

    flines[["LENGTHKM"]][flines_to_update_index] <- # Adjust the length of the set we need to update.
      flines[["LENGTHKM"]][flines_to_update_index] + flines[["LENGTHKM"]][short_flines_index]

    # Set LENGTHKM to 0 since this one's gone from the network.
    flines[["LENGTHKM"]][short_flines_index] <- 0
    flines[["toCOMID"]][flines_to_update_index] <- NA

    # Check if the eliminated COMID had anything going to it.
    need_to_update_index <- which(flines$joined_fromCOMID %in% short_flines$COMID)
    flines[["joined_fromCOMID"]][need_to_update_index] <- short_flines$fromCOMID

    # Mark the ones that are being removed with which comid they got joined with.
    flines[["joined_fromCOMID"]][short_flines_index] <- short_flines$fromCOMID

    short_outlets_tracker <- c(short_outlets_tracker, flines[["COMID"]][short_flines_index])

    count <- count + 1
    if (count > 100) stop("stuck in short outlet loop")
  }
  return(list(flines = flines, short_outlets_tracker = short_outlets_tracker))
}