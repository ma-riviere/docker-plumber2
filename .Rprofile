if (!nzchar(Sys.getenv("RENV_PROFILE"))) {
    Sys.setenv(RENV_PROFILE = paste0("docker-", R.version$major, ".", sub("\\..*", "", R.version$minor)))
}
source("r-utils/init.R")
source("renv/activate.R")
