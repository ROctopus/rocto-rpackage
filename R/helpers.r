# Check whether directory is a valid job
.roctoCheck <- function(dir, tdir, interactive = TRUE) {
  fulldir <- normalizePath(dir)
  wrns <- msgs <- c()
  if (!dir.exists(dir)) {
    wrns <- c(wrns, "Job directory does not exist")
  } else {
    # first copy to tempdir and switch to it.
    copySuccess <- file.copy(fulldir, tdir, recursive = TRUE)
    if (copySuccess) {
      tempwd <- file.path(tdir, basename(fulldir))
    } else {
      stop("Temporary directory not available; could not check your package. Perhaps you don't have the correct permissions.")
    }
    
    lst <- list.files(tempwd)
    fileExp <- c("main.R", "params.R") 
    fileChk <- fileExp %in% lst
    if (!all(fileChk)) {
      wrns <- c(wrns, sprintf("Missing file: ", fileExp[!fileChk]))
    } else {
      # create environment to evaluate the functions in main and params
      paramEnv <- new.env()
      mainEnv <- new.env()
      mainSourced <- try(source(file.path(tempwd,"main.R"), mainEnv), silent = TRUE)
      paramsSourced <- try(source(file.path(tempwd,"params.R"), paramEnv), silent = TRUE)
      
      if (inherits(mainSourced, "try-error")) {
        # remove call
        w <- trimws(sub("[^:]*: ", "", mainSourced[1], perl = TRUE)) 
        wrns <- c(wrns, w)
      }
      
      if (inherits(paramsSourced, "try-error")) {
        # remove call
        w <- trimws(sub("[^:]*: ", "", paramsSourced[1], perl = TRUE)) 
        wrns <- c(wrns, w)
      }
      
      if (!inherits(mainSourced, "try-error") && 
          !inherits(paramsSourced, "try-error")) {
        # check that testParams exist in the params file and that they contain all
        # iterated parameters
        parItr <- ls(paramEnv)
        if (!"testParams" %in% parItr) {
          wrns <- c(wrns, "testParams not found!")
        } else {
          parItr <- parItr[parItr != "testParams"]
          parTst <- names(paramEnv$testParams)
          if (!suppressWarnings(all(sort(parItr) == sort(parTst)))) {
            wrns <- c(wrns, "Elements of testParams are not the same as iterated params!")
          } else {
            for (p in parTst) {
              if (class(paramEnv$testParams[[p]]) != class(paramEnv[[p]])) {
                wrns <- c(wrns, sprintf("testParam '%s' does not have the same class as its iterated counterpart!", p))
              }
            }
          }
        }
        
        # check that all params are used in main and all main params are iterated
        parUse <- names(formals(mainEnv$main))
        parChk <- parItr %in% parUse
        if (!all(parChk)) {
          wrns <- c(wrns, sprintf("Unused parameter in main: %s", parItr[!parChk]))
        }
        
        parChk <- parUse %in% parItr
        if (!all(parChk)) {
          wrns <- c(wrns, sprintf("Parameter used in main but not iterated: %s", 
                                  parUse[!parChk]))
        }
      }
      
      # Check whether the files used in the roctoJob are available
      uf <- .findUsedFiles(file.path(tempwd,"main.R"))
      if (!is.null(uf)) {
        for (fi in uf) {
          if (!file.exists(fi) && !dir.exists(fi)) {
            wrns <- c(wrns, sprintf("Used file '%s' not found.", fi))
          }
        }
      }
    }
    
    if (!dir.exists(file.path(tempwd,"data"))) {
      msgs <- c(msgs, "Data directory does not exist")
    }
    
    
  }
  
  
  # Check for warnings and messages and return result
  if (length(wrns) > 0) {
    cat("\nJob package check failed! Inspect the warning messages and adjust your code accordingly.")
    for (w in wrns) {
      warning(w, call. = FALSE)
    }
    for (m in msgs) {
      message(m)
    }
    message("")
    res <- FALSE
    attr(res, "warnings") <- wrns
    attr(res, "messages") <- msgs
  } else {
    if (length(msgs) > 0) {
      for (m in msgs) {
        message(m)
      }
      message("")
      if (interactive) {
        cont <- utils::menu(c("Yes", "No"), title = "Proceed anyway?")
      } else {
        cont <- 1
      }
      if (cont == 1) {
        res <- TRUE
        attr(res, "messages") <- msgs
      } else {
        res <- FALSE
        attr(res, "messages") <- msgs
      }
    }
    res <- TRUE
  }
  # Remove tempdir and return
  unlink(tempwd, recursive = TRUE)
  return(invisible(res))
}

# Prepare job for packing and gather information
.prepJob <- function(dir, tdir, verbose = FALSE) {
  fulldir <- normalizePath(dir)
  # first copy to tempdir and switch to it.
  copySuccess <- file.copy(fulldir, tdir, recursive = TRUE)
  if (copySuccess) {
    tempwd <- file.path(tdir, basename(fulldir))
  } else {
    stop("Temporary directory not available; could not prepare your package. Perhaps you don't have the correct permissions.")
  }
  
  # create the parameter grid
  gridEnv <- new.env()
  source(file.path(tempwd,"params.R"), gridEnv)
  gridList <- list()
  for (p in ls(gridEnv)[ls(gridEnv) != "testParams"]) {
    gridList[[p]] <- gridEnv[[p]]
  }
  grid <- expand.grid(gridList, stringsAsFactors = FALSE)
  colnames(grid) <- names(gridList)
  save(grid, file = file.path(tempwd,"grid.Rdata"))
  
  # create meta information
  meta <- list(
    "nParams" = ncol(grid), 
    "params" = colnames(grid),
    "testParams" = gridEnv[["testParams"]],
    "nIter" = nrow(grid), 
    "dataSize" = file.size("data"), 
    "RInfo" = as.list(unlist(version)),
    "RPackages" = list(
      
    ))
  
  jsonMeta <- jsonlite::toJSON(meta, pretty = TRUE)
  write(jsonMeta, file = "meta.json")
  
  if (verbose) {
    print(grid)
    print(jsonMeta)
  }
  
  return(invisible(TRUE))
}

# Package the job, copy it next to the original folder and ask to open folder
.zipJob <- function(dir, tdir) {
  fulldir <- normalizePath(dir)
  oldwd <- getwd()
  setwd(tdir)
  filename <- paste0(basename(fulldir), ".rocto")
  if (file.exists(filename)) {
    unlink(filename)
  }
  zip::zip(filename, basename(fulldir), recurse = TRUE)
  file.copy(from = filename, to = dirname(fulldir))
  open <- utils::menu(c("Yes", "No"), title="Open containing folder?")
  if (open == 1) {
    .openFolder(dirname(fulldir))
  }
  setwd(oldwd)
  return(invisible(TRUE))
}

# regex all used packages from a rocto folder
.findUsedPackages <- function(file, namesOnly = FALSE) {
  # Determine packages used
  if (!class(text) == "character")
    stop("Input a string")
  
  text <- paste(readLines(file, warn = FALSE),collapse="\n")
  
  # Init
  
  # Check if this file sources other files
  regex <- "(?<=source\\([\\\"\\']).*(?=[\\\"\\']\\))"
  matches <- gregexpr(regex, text, perl = TRUE)[[1]]
  lengths <- attr(matches, "match.length")
  
  # If it does, recursively get the names of packages from those files
  sourcedPackages <- list()
  if (any(matches>=0)){
    for (m in seq_along(matches)){
      sourceFile <- substr(text,matches[m],matches[m]+lengths[m]-1)
      sourcedPackages[[m]] <- .findUsedPackages(sourceFile, namesOnly = TRUE)
    }
  }
  
  # Find packages used in this file
  regex <- "(?<=library\\().*(?=\\))|(?<=require\\().*(?=\\))|(?<=[ \\t\\n\\(\\{\\|\\&\\)\\}\\\"\\'])[A-Za-z0-9\\.]*(?=::)"
  matches <- gregexpr(regex, text, perl = TRUE)[[1]]
  lengths <- attr(matches, "match.length")
  
  # If there are any, get their names
  usedPackages <- NULL
  if (any(matches>=0)){
    for (m in seq_along(matches)){
      usedPackages[m] <- substr(text,matches[m],matches[m]+lengths[m]-1)
    }
  }
  
  usedPackages <- trimws(c(usedPackages, 
                           unlist(sourcedPackages, use.names = FALSE)))
  
  if (namesOnly) return(usedPackages)
  
  if (length(usedPackages)>0) {
    
    # Get the version number of each package and return output
    uniquePackages <- unique(usedPackages)
    pkgElement <- list("name"=NULL, "version"=NULL)
    out <- rep(list(pkgElement), length(uniquePackages))
    
    for (p in seq_along(uniquePackages)){
      pkg <- uniquePackages[p]
      ver <- as.character(utils::packageVersion(pkg))
      out[[p]][["name"]] <- pkg
      out[[p]][["version"]] <- ver
    }
    return(out)
    
  } else {
    
    # no packages used, return null
    return(NULL)
    
  }
}

# regex all used files from a main.r file
.findUsedFiles <- function(file) {
  # Determine files used
  if (!class(file) == "character")
    stop("Input a string")
  
  dir <- dirname(normalizePath(file))
  text <- paste(readLines(file, warn = FALSE), collapse = "\n")
  
  # Init
  
  # Check if this file sources other files
  regex <- "(?<=source\\([\\\"\\']).*(?=[\\\"\\']\\))"
  matches <- gregexpr(regex, text, perl = TRUE)[[1]]
  lengths <- attr(matches, "match.length")
  
  # If it does, recursively get the used files from these sources
  sourcedFiles <- list()
  if (any(matches >= 0)) {
    for (m in seq_along(matches)) {
      sourceFile <- substr(text, matches[m], matches[m] + lengths[m] - 1)
      if (file.exists(file.path(dir,sourceFile))) {
        sourcedFiles[[m]] <- .findUsedFiles(file.path(dir,sourceFile))
      } else {
        sourcedFiles[[m]] <- NULL
      }
    }
  }
  
  # Find files used in this file
  regex <- paste0("(?<=source\\([\\\"\\']).*(?=[\\\"\\']\\))|",
                  "(?<=load\\([\\\"\\']).*(?=[\\\"\\']\\))|",
                  "(?<=read.table\\([\\\"\\']).*(?=[\\\"\\']\\))|",
                  "(?<=read.csv\\([\\\"\\']).*(?=[\\\"\\']\\))|",
                  "(?<=read.csv2\\([\\\"\\']).*(?=[\\\"\\']\\))|",
                  "(?<=read.delim\\([\\\"\\']).*(?=[\\\"\\']\\))|",
                  "(?<=read.delim2\\([\\\"\\']).*(?=[\\\"\\']\\))|",
                  "(?<=read.fwf\\([\\\"\\']).*(?=[\\\"\\']\\))|",
                  "(?<=read_dta\\([\\\"\\']).*(?=[\\\"\\']\\))|",
                  "(?<=read_sas\\([\\\"\\']).*(?=[\\\"\\']\\))|",
                  "(?<=read_por\\([\\\"\\']).*(?=[\\\"\\']\\))|",
                  "(?<=read_json\\([\\\"\\']).*(?=[\\\"\\']\\))|",
                  "(?<=read_xml\\([\\\"\\']).*(?=[\\\"\\']\\))|",
                  "(?<=read.dcf\\([\\\"\\']).*(?=[\\\"\\']\\))|",
                  "(?<=readRDS\\([\\\"\\']).*(?=[\\\"\\']\\))|",
                  "(?<=read.arff\\([\\\"\\']).*(?=[\\\"\\']\\))|",
                  "(?<=read.dbf\\([\\\"\\']).*(?=[\\\"\\']\\))|",
                  "(?<=read.dta\\([\\\"\\']).*(?=[\\\"\\']\\))|",
                  "(?<=read.epiinfo\\([\\\"\\']).*(?=[\\\"\\']\\))|",
                  "(?<=read.mtp\\([\\\"\\']).*(?=[\\\"\\']\\))|",
                  "(?<=read.octave\\([\\\"\\']).*(?=[\\\"\\']\\))|",
                  "(?<=read.spss\\([\\\"\\']).*(?=[\\\"\\']\\))|",
                  "(?<=read.ssd\\([\\\"\\']).*(?=[\\\"\\']\\))|",
                  "(?<=read.systat\\([\\\"\\']).*(?=[\\\"\\']\\))|",
                  "(?<=read.xport\\([\\\"\\']).*(?=[\\\"\\']\\))|",
                  "(?<=read.ftable\\([\\\"\\']).*(?=[\\\"\\']\\))|")
  matches <- gregexpr(regex, text, perl = TRUE)[[1]]
  lengths <- attr(matches, "match.length")
  
  # If there are any, get their names
  usedFiles <- NULL
  if (any(matches >= 0 )) {
    for (m in seq_along(matches)) {
      usedFiles[m] <- file.path(dir, substr(text, 
                                            matches[m], 
                                            matches[m] + lengths[m] - 1))
    }
  }
  
  usedFiles <- trimws(c(usedFiles, unlist(sourcedFiles, use.names = FALSE)))
  
  return(unique(usedFiles))
}


.runJob <- function(dir, iterId) {
  o <- NULL
  .withDir(dir, {
    if (iterId == "test") {
      source("params.R")
      p <- testParams
    } else {
      load("grid.Rdata")
      p <- as.list(grid[iterId,])
    }
    
    source("main.R")
    
    # convert parameters to correct order
    pSorted <- lapply(names(formals(main)), function(n) { p[[n]] })
    
    # perform function
    o <- try(do.call(main, pSorted))
  })
  return(o)
}