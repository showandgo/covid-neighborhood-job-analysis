# Read in state control totals, and create a dataset of state x industry
# job loss estimates

library(tidyverse)
library(readxl)
library(testit)


generate_state_adjusted_job_loss_nums <- function(
                                                  past_unemployment_weeks = past_unemployment_weeks, is_bls = is_bls,
                                                  bls_advance_claims_filename = "initial-claims-bls-state.csv") {
    ## ----Read in data------------------------------------------------------
    # Read in BLS QCEW data
    qcew_all <- read_excel("data/raw-data/big/us_qcew.xlsx",
        sheet = "US_St_Cn_MSA"
    )

    # Read in state unemployment claims
    state_claims <- read_csv(
        str_glue("data/raw-data/small/{bls_advance_claims_filename}")
    )

    # Read in national industry estimates
    if (is_bls) {
        national_industry_est <- read_csv("data/processed-data/job_change_bls_most_recent.csv")
    } else {
        national_industry_est <- read_csv("data/processed-data/job_change_all_states_most_recent.csv")
    }

    # Read in FIPS codes
    fips_codes <- read_excel("data/raw-data/big/fips.xlsx",
        sheet = "nationalpluspr_17",
        skip = 4
    )

    ## ----Create state job loss figures-------------------------------------
    # Get total employment from QCEW
    qcew_sub <- qcew_all %>%
        filter(`Area Type` == "State", `Ownership` == "Total Covered") %>%
        rename(state = `St Name`, total_employment = `September Employment`) %>%
        select(state, total_employment)

    # Calculate total unemployment by state
    cols <- length(colnames(state_claims))
    state_unemp <- state_claims %>%
        data.frame(unemployment_totals = rowSums(state_claims[(cols - past_unemployment_weeks + 1):cols])) %>%
        select(state, unemployment_totals)

    # Merge and check merge and write out state job loss numbers
    state_job_loss <- state_unemp %>%
        left_join(qcew_sub, by = "state") %>%
        drop_na() %>%
        mutate(percent_change_employment = -unemployment_totals / total_employment) %>%
        write_csv("data/processed-data/state_job_loss.csv")
    assert(nrow(state_job_loss) == 51)

    ## ----Create state job loss by industry figures-------------------------

    # Calculate the factor to adjust state data to national job loss
    national_job_loss_factor <- state_job_loss %>%
        summarise(
            unemployment_totals = sum(unemployment_totals),
            total_employment = sum(total_employment)
        ) %>%
        mutate(percent_change_employment = -unemployment_totals / total_employment) %>%
        select(percent_change_employment) %>%
        pull()

    if (!is_bls) {
        # Calculate the national job loss percentage to compare to states
        national_job_loss_calc <- national_industry_est %>%
            summarise(
                tot_emp = sum(total_employment),
                unemp_tot = sum(unemployment_totals)
            ) %>%
            mutate(percent_change_employment = -unemp_tot / tot_emp) %>%
            select(percent_change_employment) %>%
            pull()

        national_job_loss_calc_ratio <- national_job_loss_factor / (national_job_loss_calc**2)
    } else {
        national_job_loss_calc_ratio <- 1 / national_job_loss_factor
    }

    # Function that takes state as input, and returns a dataframe with the
    # state's job loss by industry estimates
    # input: state, string
    # output: state_industry_est, dataframe
    create_state_estimates <- function(st) {
        state_job_loss_calc <- state_job_loss %>%
            filter(state == st) %>%
            select(percent_change_employment) %>%
            pull()
        state_job_loss_constant <- state_job_loss_calc * national_job_loss_calc_ratio
        state_industry_est <- national_industry_est %>%
            mutate(
                factor = state_job_loss_constant,
                percent_change_employment_st = state_job_loss_constant * percent_change_employment,
                state = st
            )
        state_industry_est
    }

    # Filter FIPS
    fips_ready <- fips_codes %>%
        filter(`Summary Level` == "040") %>%
        rename(
            state_fips = `State Code (FIPS)`,
            state = `Area Name (including legal/statistical area description)`
        ) %>%
        select(state, state_fips)

    # Merge
    state_job_estimates <- state_job_loss$state %>%
        map(create_state_estimates) %>%
        bind_rows() %>%
        left_join(fips_ready, by = "state")

    if (!is_bls) {
        # Replace WA and NY with actuals
        wa <- read_csv("data/processed-data/job_change_wa_most_recent.csv")
        ny <- read_csv("data/processed-data/job_change_ny_most_recent.csv")
        replace_state <- function(st_name, st_fips, df) {
            temp_state <- df %>%
                mutate(
                    state_fips = st_fips, state = st_name,
                    percent_change_employment_st = percent_change_employment,
                    factor = 1
                )
            temp_state_job_estimates <- state_job_estimates %>%
                filter(state_fips != st_fips) %>%
                rbind(temp_state)
            temp_state_job_estimates
        }
        state_job_estimates <- replace_state("Washington", "53", wa)
        state_job_estimates <- replace_state("New York", "36", ny)
    } else {
        # If values are positive job change, correct using the inverse
        jobs_negative <- state_job_estimates %>%
            filter(percent_change_employment < 0)
        jobs_positive <- state_job_estimates %>%
            filter(percent_change_employment >= 0) %>%
            mutate(
                factor = 1 / factor,
                percent_change_employment_st = percent_change_employment * factor
            )
        state_job_estimates <- jobs_negative %>%
            rbind(jobs_positive) %>%
            arrange(state, lodes_var)
    }

    # Write out state adjusted job loss estimates
    state_job_estimates %>%
        write_csv("data/processed-data/state_job_change_all_states_most_recent.csv")
}

generate_state_adjusted_job_loss_nums(
    is_bls = is_bls,
    past_unemployment_weeks = past_unemployment_weeks
)