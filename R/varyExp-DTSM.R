library(ggplot2)
# library(tidyverse)
library(magrittr)
library(tibble)
library(tidyr)
library(dplyr)

default_nuTail <- function(x, t) {
  if (t <= 0)
    Inf
  else
    t ^ (-0.7) / gamma(1 - 0.7)
}
default_a <- function(x,t) 
  0.9
default_b <- function(x,t)
  0
default_d <- function(x) 
  0

# Creates a delta function initial condition, with "delta function" located 
# in the center lattice point.
# arguments: 
#   xrange: a pair of numbers (xmin, xmax)
#   age_max: cutoff of age lattice
#   c: master scaling parameter
#   chi: spatial lattice spacing
#   tau: age lattice spacing
#   nuTail: space-dependent tail function of Levy measure
#   d: space-dependent temporal drift
# returns: a list of two items: 
#   * an (m,n) matrix of the CTRW states, with the first dimension
#     corresponding to space and the second to age
#   * an (m,n) matrix of survival probabilities
init_delta <- function(xrange,
                      age_max,
                      c,
                      chi,
                      tau,
                      nuTail,
                      theta, 
                      where = c("centre", "left")) {
  # set up space-age-lattice
  m <- round((xrange[2] - xrange[1]) / chi)
  if (m %% 2 == 0)
    m <- m+1 # to make m odd
  x <- seq(from = xrange[1],
           to = xrange[2],
           length.out = m)
  n <- round(age_max / tau)
  xi0 <- matrix(0, m, n)
  where <- match.arg(where)
  if (where == "centre") {
    # Put initial mass on center two lattice points with age 0:
    midpoint_index <- (m+1)/2
    xi0[midpoint_index, 1]  <- 1 / chi
  }
  if (where == "left") {
    xi0[1, 1] <- 1 / chi
  }
  
  # set up survival probability matrix
  # begin with nonlocal part:
  Psi_nonloc <- function(x, t)
    min(1, nuTail(x, t) / c)
  age <- (0:n) * tau
  h <- (1-theta(x)) * outer(x, age, Vectorize(Psi_nonloc)) # see paper for definition of h
  # now add the local part of psi:
  h[ , 1] <- 1
  
  if (!all(h >= 0))
    stop("Survival function can't be negative.")
  survival_probs <- h[ , -1] / h[ , -(n+1)]
  # Zeros can occur. Dividing by 0 gives an NaN. We want these to be 0.
  survival_probs[is.na(survival_probs)] <- 0
  if (!all(survival_probs >= 0))
    stop("Make sure nuTail is decreasing in t.")

  list(xi0 = xi0, survival_probs = survival_probs)
}

# calculates jump probabilities
# arguments: 
#   b, a: space- and time-dependent drift and diffusivity
#   x: a vector of locations
#   t: the current time (float)
# returns: 
#   a list with three items, each a vector of same length as x, 
#   for the probabilities to jump left, right and self-jumps
jump_probs <- function(x, t, a_trans, b_trans) {
  m <- length(x)
  chi <- diff(range(x)) / (m-1)
  a_vec <- sapply(x, function(x) a_trans(x,t))
  if (!all(a_vec >= 0))
    stop("Diffusivity can't be negative.")
  b_vec <- sapply(x, function(x) b_trans(x,t))
  #if (!all(chi * abs(b_vec) <= a_vec))
  #  message("Warning: some jump probabilities are being truncated.")
  left  <- ((a_vec - chi * b_vec) / 2) %>% 
    sapply(function(x) max(0,x)) %>%
    sapply(function(x) min(1,x))
  right <- ((a_vec + chi * b_vec) / 2) %>% 
    sapply(function(x) max(0,x)) %>%
    sapply(function(x) min(1,x))
  center <- 1 - left - right
  # boundary conditions left end
  center[1] <- center[1] + left[1]
  left[1] <- 0
  #boundary conditions right end
  center[m] <- center[m] + right[m]
  right[m] <- 0
  list(left = left,
       center = center,
       right = right)
}

# evolve xi by one step
step_xi <- function(xi, Sprob, Jprob) {
  #Evaluate survivals, escapes and jumps
  surviving <- xi * Sprob
  escaping <- rowSums(xi - surviving)
  self_jumping  <- escaping * Jprob$center
  right_jumping <- escaping * Jprob$right
  left_jumping  <- escaping * Jprob$left
  
  #Update grid with survivals, escapes and jumps
  m <- dim(xi)[1]
  n <- dim(xi)[2]
  # increment age of surviving particles
  xi[ , -1] <- surviving[ , -n]
  # don't increment age of oldest particles
  xi[ , n] <- xi[ , n] + surviving[, n]
  # place escaping particles back on grid
  xi[ , 1] <- self_jumping + c(0, right_jumping[-m]) + c(left_jumping[-1], 0)
  xi
}


# Computes location-age densities for various snapshots in time.
# Arguments: 
#   xrange: 2-vector delineating the domain
#   snapshots: a vector of times at which location-age densities xi are computed
#   age_max: maximum age
#   c: master scaling parameter
#   chi: spatial grid parameter
#   tau: temporal grid parameter
#   a: diffusivity
#   b: drift
#   nuTail: tail function of Levy measure
#   d: temporal drift, between 0 and 1
# Returns:
#   a list with itmes: 
#       1. list of xis at the snapshots
#       2. the xrange
#       3. the snapshots
DTSM <- function(xrange = c(-2, 2),
                 snapshots = c(0.5, 1, 2),
                 age_max = max(snapshots),
                 c = 100,
                 chi = 1/sqrt(c),
                 tau = 1/c,
                 a = default_a,
                 b = default_b,
                 nuTail = default_nuTail,
                 d = default_d, 
                 initial_condition = "centre") {
  # transform parameters
  theta <- Vectorize(function(x)
    d(x) / (1 + d(x)))
  a_trans <- function(x,t)
    (1-theta(x)) * a(x,t)
  b_trans <- function(x,t)
    (1-theta(x)) * b(x,t)
  
  foo <-
    init_delta(
      xrange = xrange,
      age_max = age_max,
      c = c,
      chi = chi,
      tau = tau,
      nuTail = nuTail,
      theta = theta, 
      where = initial_condition
    )
  xi   <- foo$xi0
  Sprob <- foo$survival_probs
  m <- dim(xi)[1]
  n <- dim(xi)[2]
  x <- seq(from = xrange[1],
           to = xrange[2],
           length.out = m)
  N <- length(snapshots)
  xi_list <- vector("list", N)
  t <- 0
  counter <- 0
  message("Need ", round(max(snapshots) / tau), " iterations.")
  for (i in 1:N) {
    while (t + tau <= snapshots[i]) {
      t <- t + tau
      counter <- counter + 1
      if (counter %% 1000 == 0)
        message("Finished ", counter, " iterations.")
      Jprob <- jump_probs(x = x, t = t, a_trans = a_trans, b_trans = b_trans)
      xi <- step_xi(xi = xi,
                    Sprob = Sprob,
                    Jprob = Jprob)
    }
    xi_list[[i]] <- xi
  }
  list(xi_list = xi_list, xrange = xrange, snapshots = snapshots)
}

rho_df <- function(DTSM_output) {
  xi_list   <- DTSM_output[["xi_list"]]
  xrange    <- DTSM_output[["xrange"]]
  snapshots <- DTSM_output[["snapshots"]]
  N   <- length(xi_list)
  xi  <- xi_list[[1]]
  m   <- dim(xi)[1]
  x   <- seq(xrange[1], xrange[2], length.out = m)
  out <- tibble(x = x)
  for (i in 1:N) {
    rho <- rowSums(xi_list[[i]])
    out[paste0("t_", i, "=", snapshots[i])] <- rho
  }
  out
}
