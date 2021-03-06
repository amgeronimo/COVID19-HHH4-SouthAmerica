# LOAD REQUIRED PACKAGES AND FUNCTIONS -----------------------------------------
if (!require("pacman")) install.packages("pacman")
pkgs = c("surveillance", "dplyr", "sp", "sf", "hhh4addon",
         "ggplot2", "hhh4addon") # package names
pacman::p_load(pkgs, character.only = T)

source("R/functions.R")

# LOAD DATA --------------------------------------------------------------------

# Cases at country level
counts <- readRDS("data/processed/daily_cases.rds")

# Shapefile for Africa
samerica <- st_read("data/processed/geodata/samerica.gpkg") 

## Weather
#weather_clean <- readr::read_csv("data/original/AfricaCountries_2020-12-08_ALLEXTRACTEDDATA.csv")

# DATA PREPARATION -------------------------------------------------------------

# Policy variables
# Sindex is divided by 10 to show a 10% increase per unit increase
sindex <- readRDS("data/processed/stringency.rds") / 10
testing <- readRDS("data/processed/testing.rds")
vax <- readRDS("data/processed/vax.rds")

## Weather data 
#rain_mean <- extrac_var_climate(var = "rain_mean", data = weather_clean)
#temp_mean <- extrac_var_climate(var = "temp_mean", data = weather_clean)
#sh_mean <- extrac_var_climate(var = "sh_mean", data = weather_clean) 

## Standardise climatic variables
#rain_mean <- (rain_mean - mean(rain_mean)) / sd(rain_mean)
#temp_mean <- (temp_mean - mean(temp_mean)) / sd(temp_mean)
#sh_mean <- (sh_mean - mean(sh_mean)) / sd(sh_mean)


# See what the common dates are for the time varying datasets and censor
# accordingly THIS IS ALREADY DONE IN DATA PROCESSING
#final_dates <- Reduce(intersect, list(rownames(rain_mean), rownames(counts), 
#                                      rownames(sindex)))
#counts <- counts[rownames(counts) %in% final_dates, ]
#sindex <- sindex[rownames(sindex) %in% final_dates, ]
#testing <- testing[rownames(testing) %in% final_dates, ]

# Check that the order of cases and countries in the shapefile are the same
all(colnames(counts) == samerica$name)

map <- as(samerica, "Spatial")
row.names(map) <- as.character(samerica$name)

# Create adj mat and neighbours order
map_adjmat <- poly2adjmat(map)
map_nbOrder <- nbOrder(map_adjmat, maxlag = Inf)

epi_sts <- sts(observed = counts,
               #start = c(2020, 23),
               start = c(lubridate::year(as.Date(rownames(counts)[1])), lubridate::yday(as.Date(rownames(counts)[1]))),
               frequency = 365,
               population = samerica$Pop2020 / sum(samerica$Pop2020),
               neighbourhood = map_nbOrder,
               map = map)

# Create covariates 

# Population
pop <- population(epi_sts)


# HDI by category
HDI_cat <- as.numeric(samerica$HDI)
HDI_cat <- matrix(HDI_cat, ncol = ncol(epi_sts), nrow = nrow(epi_sts),
                  byrow = T)

# Median age
mage <- matrix(samerica$Age, ncol = ncol(epi_sts), nrow = nrow(epi_sts),
               byrow = T)

#SSA <- matrix(1 - africa$North_Afri, 
#              ncol = ncol(epi_sts), nrow = nrow(epi_sts),
#              byrow = T)

#LL <- matrix(africa$landlock, 
#             ncol = ncol(epi_sts), nrow = nrow(epi_sts),
#             byrow = T)

# Lag time varying variables
k <- 7
sindex_lag <- xts::lag.xts(sindex, k = 7)
testing_lag <- xts::lag.xts(testing, k = 7)
vax_lag <- xts::lag.xts(vax,k=7)
#temp_mean_lag <- xts::lag.xts(temp_mean, k = 7)
#rain_mean_lag <- xts::lag.xts(rain_mean, k = 7)
#sh_mean_lag <- xts::lag.xts(sh_mean, k = 7)

# MODEL ------------------------------------------------------------------------
start_day <- "2021-03-01"
end_day <- "2021-06-20"

fit_start <- which(rownames(counts) == start_day) 
fit_end <- which(rownames(counts) == end_day) 

# Best AR1 model with no RE 
f_end <- ~ 1 
#f_ar <- ~ 1 + log(pop) + HDI_cat + LL + sindex_lag + testing_lag + 
#  rain_mean_lag + temp_mean_lag + sh_mean_lag 
f_ar <- ~ 1 + log(pop) + HDI_cat  + sindex_lag + testing_lag + vax_lag
f_ne <- ~ 1 + log(pop) + HDI_cat  + sindex_lag + testing_lag + vax_lag


model_basic <- list(
  end = list(f = f_end, offset = population(epi_sts)),
  ar = list(f = f_ar),
  ne = list(f = f_ne, weights = W_powerlaw(maxlag = 9)),
  optimizer = list(stop = list(iter.max = 50)),
  family = "NegBin1",
  subset = fit_start:fit_end)

fit_basic <- hhh4(epi_sts, control = model_basic)

# Lagged version of previous model 
f_end <- ~ 1 
f_ar <- ~ 1 + log(pop) + HDI_cat + sindex_lag + testing_lag + vax_lag
f_ne <- ~ 1 + log(pop) + HDI_cat + sindex_lag + testing_lag + vax_lag
lags <- 14

AIC_poisson <- numeric(lags - 1)
for (i in 1:(lags - 1)) {
  model_lag <- list(
    end = list(f = f_end, offset = population(epi_sts)),
    ar = list(f = f_ar),
    ne = list(f = f_ne, weights = W_powerlaw(maxlag = 9)),
    optimizer = list(stop = list(iter.max = 50)),
    family = "NegBin1",
    subset = fit_start:fit_end,
    funct_lag = poisson_lag, 
    max_lag = i + 1)
  
  fit_lag_pois <- profile_par_lag(epi_sts, model_lag) # now use hhh4lag
  AIC_poisson[i] <- AIC(fit_lag_pois)
  print(i)
}

AIC_geom <- numeric(lags - 1)
for (i in 1:(lags - 1)) {
  model_lag <- list(
    end = list(f = f_end, offset = population(epi_sts)),
    ar = list(f = f_ar),
    ne = list(f = f_ne, weights = W_powerlaw(maxlag = 9)),
    optimizer = list(stop = list(iter.max = 50)),
    family = "NegBin1",
    subset = fit_start:fit_end,
    funct_lag = geometric_lag, 
    max_lag = i + 1)
  
  fit_lag_geom <- profile_par_lag(epi_sts, model_lag) # now use hhh4lag
  AIC_geom[i] <- AIC(fit_lag_geom)
  print(i)
}


# AIC table
tibble(p = 2:lags, Geometric = AIC_geom, Poisson = AIC_poisson, 
       aic_baseline = AIC(fit_basic)) %>% 
  tidyr::gather(key = "dist", value = "AIC", -p, -aic_baseline) %>% 
  mutate(diff = AIC - aic_baseline) %>% 
  ggplot(aes(x = p, y = diff, col = dist)) +
  geom_line() +
  geom_point() +
  labs(y = "Improvement in AIC", x = "D") +
  scale_color_brewer("", type = "q", palette = 6) +
  scale_x_continuous(breaks = 2:14) +
  theme_gray(base_size = 13) +
  theme(legend.position = "top") 

ggsave("figs/figureS10A.pdf", width = 7, height = 5)

# FIT BEST POISSON AND GEOMETRIC MODEL WITH OPTIMAL LAG AND PLOT WEIGHTS

# Geometric
model_lag <- list(
  end = list(f = f_end, offset = population(epi_sts)),
  ar = list(f = f_ar),
  ne = list(f = f_ne, weights = W_powerlaw(maxlag = 9)),
  optimizer = list(stop = list(iter.max = 50)),
  family = "NegBin1",
  subset = fit_start:fit_end,
  funct_lag = geometric_lag, 
  max_lag = 14)

fit_lag <- profile_par_lag(epi_sts, model_lag)
summary(fit_lag, idx2Exp = T)
confint(fit_lag, parm = "overdisp")

AIC(fit_lag)

wgeom <- fit_lag$distr_lag

model_lag <- list(
  end = list(f = f_end, offset = population(epi_sts)),
  ar = list(f = f_ar),
  ne = list(f = f_ne, weights = W_powerlaw(maxlag = 9)),
  optimizer = list(stop = list(iter.max = 50)),
  family = "NegBin1",
  subset = fit_start:fit_end,
  funct_lag = poisson_lag, 
  max_lag = 14)

fit_lag <- profile_par_lag(epi_sts, model_lag)
summary(fit_lag, idx2Exp = T)
confint(fit_lag, parm = "overdisp")

AIC(fit_lag)

wpois <- fit_lag$distr_lag

tibble(dist = rep(c("Geometric", "Poisson"), each = length(wgeom)),
       weight = c(wgeom, wpois), lag = rep(1:14, 2)) %>% 
  ggplot(aes(x = lag, y = weight, fill = dist)) +
  geom_bar(stat = "identity", position = position_dodge(), col = "black") +
  labs(x = "d", y = expression(w[d])) + 
  scale_x_continuous(breaks = 1:14) +
  scale_fill_brewer("", type = "q", palette = 6) +
  theme_gray(base_size = 13) +
  theme(legend.position = "top") 

ggsave("figs/figureS10B.pdf", width = 7, height = 5)


# LAGGED POISSON WITH AND WITHOUT RE WITH OPTIMAL NUMBER OF LAGS  
lag_optimal <- 7
f_end <- ~ 1 
f_ar <- ~ 1 + log(pop) + HDI_cat + sindex_lag + testing_lag + vax_lag
f_ne <- ~ 1 + log(pop) + HDI_cat + sindex_lag + testing_lag + vax_lag
  
  
model_lag <- list(
  end = list(f = f_end, offset = population(epi_sts)),
  ar = list(f = f_ar),
  ne = list(f = f_ne, weights = W_powerlaw(maxlag = 9)),
  optimizer = list(stop = list(iter.max = 50)),
  family = "NegBin1",
  data = list(pop = pop, HDI_cat = HDI_cat,
              sindex_lag = sindex_lag,
              testing_lag = testing_lag),
  subset = fit_start:fit_end,
  funct_lag = poisson_lag, 
  max_lag = lag_optimal)
  
fit_lag <- profile_par_lag(epi_sts, model_lag)
summary(fit_lag, idx2Exp = T)
confint(fit_lag, parm = "overdisp")
wpois <-   fit_lag$distr_lag
  
saveRDS(fit_lag, paste0("output/models/fitted_model_LAG", lag_optimal, ".rds"))
  
fit <- fit_lag
nterms <- terms(fit)$nGroups + 2
coefs <- exp(coef(fit)[1:nterms])
CIs <- exp(confint(fit)[1:nterms, ])
id_log <-  c(grep("over", names(coefs)), grep("neweights.d", names(coefs)))
coefs[id_log] <- log(coefs[id_log])
CIs[id_log, ] <- log(CIs[id_log, ])
tab <- round(cbind(coefs, CIs), 3)
  
# Calculate scores of predictive performance
tp <- c(fit_end, nrow(epi_sts) - 1)
forecast <- oneStepAhead_hhh4lag(fit, tp = tp, type = "final")
fitScores <- colMeans(scores(forecast))
# Produce final summary table
tab <- rbind(cbind(Params = rownames(tab), tab), 
             c("", "", "", ""),
             c("AIC", round(AIC(fit), 2), "", ""),
             c("", "", "", ""),
             names(fitScores),
             round(as.numeric(fitScores), 3))
write.csv(tab, paste0("output/tables/tab_params_LAG", lag_optimal, ".csv"),
          row.names = F)
  
# # INTRODUCE REs
# f_end <- ~ 1 
# f_ar <- ~ -1 + log(pop) + HDI_cat + sindex_lag + testing_lag + ri()
# f_ne <- ~ -1 + log(pop) + HDI_cat + sindex_lag + testing_lag + ri() #non convergent
# 
#   
# model_lag <- list(
#   end = list(f = f_end, offset = population(epi_sts)),
#   ar = list(f = f_ar),
#   ne = list(f = f_ne, weights = W_powerlaw(maxlag = 3)),
#   optimizer = list(stop = list(iter.max = 1)),
#   family = "NegBin1",
#   data = list(pop = pop, HDI_cat = HDI_cat,
#               sindex_lag = sindex_lag,
#               testing_lag = testing_lag),
#   subset = fit_start:fit_end,
#   funct_lag = poisson_lag, 
#   par_lag = fit_lag$par_lag,
#   max_lag = lag_optimal)
#   
# fit_lag <- hhh4_lag(epi_sts, model_lag)
# saveRDS(fit_lag, paste0("output/models/fitted_model_LAG", lag_optimal, "_RE.rds"))
#   
# fit <- fit_lag
# nterms <- terms(fit)$nGroups + 2
# coefs <- exp(coef(fit)[1:nterms])
# CIs <- exp(confint(fit)[1:nterms, ])
# id_log <-  c(grep("over", names(coefs)), grep("neweights.d", names(coefs)))
# coefs[id_log] <- log(coefs[id_log])
# CIs[id_log, ] <- log(CIs[id_log, ])
# tab <- round(cbind(coefs, CIs), 3)
# 
# # Calculate scores of predictive performance
# tp <- c(fit_end, nrow(epi_sts) - 1)
# forecast <- oneStepAhead_hhh4lag(fit, tp = tp, type = "final")
# fitScores <- colMeans(scores(forecast))
# # Produce final summary table
# tab <- rbind(cbind(Params = rownames(tab), tab), 
#              c("", "", "", ""),
#              c("AIC", round(AIC(fit), 2), "", ""),
#              c("", "", "", ""),
#              names(fitScores),
#              round(as.numeric(fitScores), 3))
# write.csv(tab, paste0("output/tables/tab_params_LAG", lag_optimal, "_RE.csv"),
#           row.names = F)

# P - VALUES -------------------------------------------------------------------
beta_hat <- fit$coefficients[1:16]
sd_hat <- fit$se[1:16]
all.equal(names(beta_hat), names(sd_hat))

zscores <- beta_hat / sd_hat
pvalues <- 2 * pnorm(abs(zscores), lower.tail = F)
cbind(round(pvalues, 3), round(pvalues, 4))