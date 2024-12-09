#Principal Component Analysis of well-level data to reduce dimensionality
#Global Mahalanobis distance calculations

library(stats)
library(factoextra)
library(tcplfit2)
library(patchwork)
library(cowplot)

#test_chem_well.RData as input

#Eliminate feats with no variance across samples
variances <- apply(well_data, 2, var)
no_var <- which(variances == 0)

well_data <- well_data[, -no_var]

#Principal component analysis (PCA)
pca <- prcomp(well_data, center = TRUE, scale = TRUE)
#pca_x <- pca$x

#Scree plot
scree_plot <- fviz_eig(pca, addlabels = T, ylim = c(0,75), main = paste0("Scree plot"))  
scree_plot

#Calculate the number of PCs that describe >95% variance
cumulative_prop <- cumsum(pca$sdev^2)/sum(pca$sdev^2)

PC_90 <- length(which(cumulative_prop<0.90))+1
PC_95 <- length(which(cumulative_prop<0.95))+1
PC_99 <- length(which(cumulative_prop<0.99))+1

#Plot PCs (Nyffeler 2021 code)
if(FALSE){
a <- length(cumulative_prop)
  
plot(x=1:a, y=cumulative_prop, col="gray50", pch=19, cex=0.5, type="p",
     ylim=c(0,1), xlab="# of components", ylab="Proportion of variance retained", main="Principal components of HTPP U-2OS data")
  #horizontal part
  segments(x0=30, y0=0.90, x1 = PC_90, col="blue", lty='dashed')
  segments(x0=30, y0=0.95, x1 = PC_95, col="blue", lty='solid', lwd=2)
  segments(x0=30, y0=0.99, x1 = PC_99, col="blue", lty='dotted')
  #vertical part
  segments(x0=PC_90, y0=0.1, y1 = 0.90, col="blue", lty='dashed')
  segments(x0=PC_95, y0=0.1, y1 = 0.95, col="blue", lty='solid', lwd=2)
  segments(x0=PC_99, y0=0.1, y1 = 0.99, col="blue", lty='dotted')
  text(x=c(PC_90, PC_95, PC_99), y=0.05, labels=c(PC_90, PC_95, PC_99), srt=90)
  text(x=0, y=c(0.9, 0.95, 0.99),  labels=paste0(c(90,95,99), "%"), cex=0.7)
}
  
#Rotation Matrix
a <- ncol(pca$rotation)

pca_x <- as.data.frame(pca$x)
pca_x <- as.data.frame(cbind(chem = rownames(well_data), pca_x)) 

DMSO_pc <- pca_x %>%
  filter(grepl("DMSO", chem))

DMSO_pc <- DMSO_pc[,-c(1)]

DMSO_mean <- colMeans(DMSO_pc)

dat <- as.matrix(well_data) %*% pca$rotation[,1:PC_95]

#Covariance Matrix
Cov <- cov(dat)

#Checkpoint
det(Cov)
isSymmetric(Cov)

#Mahalanobis distance determination

mahal_dist <- mahalanobis(dat, DMSO_mean, Cov, inverted = F) 

mahal_dist <- as.data.frame(mahal_dist)

mahal_dist <- cbind(chem = rownames(well_data), mahal_dist)

sample <- as.data.frame(mahal_dist$chem)
colnames(sample) <- "sample"

sample <- tibble(sample) %>%
  separate(sample, c("chem", "concentration", "Well", "Plate"), sep = "_", remove = T)

mahal_dist <- cbind(sample, mahal_dist = mahal_dist$mahal_dist)

mahal_dist <- mahal_dist %>%
  select(-c("Plate"))

mahal_dist$concentration <- as.numeric(mahal_dist$concentration)

mahal_dist <- mahal_dist %>%
  group_by(chem) %>%
  mutate(conc_count = length(unique(concentration)))

mahal_dmso <- mahal_dist %>%
  filter(chem == "DMSO")

mahal_dist <- mahal_dist %>%
  filter(conc_count > 3) 

mahal_dist <- rbind(mahal_dist, mahal_dmso)

#Plot Mahalanobis distances 
chem_list <- unique(mahal_dist$chem)

mahal_dist[mahal_dist$chem == "DMSO",]$concentration <- 1

ggsave(paste0(results_dir, paste0(chem_list, collapse = "_"), "_Global Mahalanobis.jpeg"),
       
       ggplot(mahal_dist, aes(x=concentration, y=mahal_dist, colour=chem)) + 
         geom_point() + 
         scale_y_continuous() +
         scale_x_log10() +
         xlab("Concentration \u03BCM") +
         ylab("Mahalanobis Distance") +
         geom_text(aes(label = Well), size = 2, vjust = -1, hjust = 0.5) +
         facet_wrap(vars(chem), scales = "free"),
       
       width = 35, height = 20, units = "cm"
       ) 

#####Tcplfit2 to derive benchmark concentrations#####

test_chem_res <- mahal_dist %>%
  filter(chem !="DMSO")

chem_list <- unique(test_chem_res$chem)

DMSO_dist <- mahal_dist %>%
  filter(chem == "DMSO")

vehicle_ctrl <- mahal_dist %>%
  filter(chem == "DMSO") %>%
  summarise(Median = median(mahal_dist, na.rm=T), 
            nMad = mad(mahal_dist, constant=1.4826, na.rm=T))

#Function to model concentration-response using concRespCore of tcplfit2
conc_res_modeling <- function(test_chem, vehicle_ctrl){ 
  
  row <- list(conc = as.numeric(test_chem$concentration),
             resp = test_chem$mahal_dist,
             bmed = vehicle_ctrl$Median,
             cutoff = vehicle_ctrl$nMad,
             onesd = vehicle_ctrl$nMad,
             name = paste0(test_chem$chem[1]),
             assay = "Mahalanobis distance (cutoff = 1)")
  
  concRespCore(row, conthits = TRUE, aicc = FALSE, force.fit = FALSE,  bidirectional = TRUE,
            fitmodels=c("cnst", "hill", "poly1", "poly2", "pow", "exp2", "exp3","exp4", "exp5"),
            bmr_scale = 1.349)
  
  }

#Function to model concentration-response using concRespCore of tcplfit2 using the lowest concentration as baseline
if(FALSE){
conc_resp_noVC <- function(test_chem){ 
  
  row <- list(conc = as.numeric(test_chem$concentration),
              resp = test_chem$mahal_dist,
              bmed = median(test_chem[test_chem$concentration == min(test_chem$concentration), "mahal_dist"]),
              cutoff = mad(test_chem[test_chem$concentration == min(test_chem$concentration), "mahal_dist"]),
              onesd = mad(test_chem[test_chem$concentration == min(test_chem$concentration), "mahal_dist"]),
              name = paste0(test_chem$chem[1]),
              assay = "Mahalanobis distance (cutoff = 1)")
  
  concRespCore(row, conthits = TRUE, aicc = FALSE, force.fit = FALSE,  bidirectional = TRUE,
               fitmodels=c("cnst", "hill", "poly1", "poly2", "pow", "exp2", "exp3","exp4", "exp5")
              )
  
}
}

#Model concentration-response for each chemical and plot individually  

tcpl_results <- lapply(chem_list, function(x){
    chem_data <- test_chem_res %>%
      filter(chem == x)
    tcpl_chem <- conc_res_modeling(chem_data, vehicle_ctrl)
    
    jpeg(file = paste0(results_dir, plates[n], "_", x, "_tcplfit.jpg"))
    concRespPlot(tcpl_chem, ymin= min(chem_data$mahal_dist)-5, ymax=max(chem_data$mahal_dist)+10, draw.error.arrows = FALSE)
    dev.off()
    
    tcpl_chem
    }) %>%
      do.call(rbind, .)

#Model concentration-response for each chemical and plot individually  
if(FALSE){
  tcpl_noVC <- lapply(chem_list, function(x){
  chem_data <- test_chem_res %>%
    filter(grepl(x, chem))
  tcpl_chem <- conc_resp_noVC(chem_data)
  concRespPlot(tcpl_chem, ymin= min(chem_data$mahal_dist)-5, ymax=max(chem_data$mahal_dist)+10,  draw.error.arrows = FALSE)
  
  tcpl_chem
}) %>%
  do.call(rbind, .)
}

#Plot all BMC, BMCU, and BMCL together
ggsave(paste0(results_dir, paste0(chem_list, collapse = "_"), "Global_BMC.jpeg"), 
       
       ggplot(tcpl_results, aes(x=bmd, y=name, colour=name)) +
         geom_point(size=2) +
         geom_errorbar(aes(xmin = bmdl, xmax = bmdu), width = 0.2) +
         scale_x_log10() +
         xlab("Median Best BMC (1SD above vehicle control) \u03BCM") +
         ylab("Chemicals"),
    
    width = 40, height = 20, units = "cm"
  )
  
#Save tcpl results
write_csv(tcpl_results, file = paste0(results_dir, plates[n], "_Global fitting Mahalanobis - tcplResult.csv"))


