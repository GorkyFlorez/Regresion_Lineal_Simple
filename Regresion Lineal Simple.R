#------------------------------------------------------------------------
library(RPostgres)
library(sf)
library(ggplot2)
library(ggspatial)
library(raster)
library(ggnewscale)

# Generar datos
set.seed(123)
x <- rnorm(100, 10, 2)
y <- 0.78*x + rnorm(100, 0, 1)

# Crear un data frame con los datos
datos <- data.frame(x, y)
datos
# Ajustar el modelo de regresión lineal simple
modelo <- lm(y ~ x, data = datos)
summary(modelo)

# Prueba de Normalidad
shapiro.test(datos$x)      #SI cumple con la noramlidad
shapiro.test(datos$y)        #SI cumple con la noramlidad

vwReg <- function(formula, data, title="", B=1000, shade=TRUE, shade.alpha=.1, spag=FALSE, spag.color="darkblue", mweight=TRUE, show.lm=FALSE, show.median = TRUE, median.col = "white", shape = 21, show.CI=FALSE, method=loess, bw=FALSE, slices=200, palette=colorRampPalette(c("#FFEDA0", "#DD0000"), bias=2)(20), ylim=NULL, quantize = "continuous",  add=FALSE, ...) {
  IV <- all.vars(formula)[2]
  DV <- all.vars(formula)[1]
  data <- na.omit(data[order(data[, IV]), c(IV, DV)])
  
  if (bw == TRUE) {
    palette <- colorRampPalette(c("#EEEEEE", "#999999", "#333333"), bias=2)(20)
  }
  
  print("Computing boostrapped smoothers ...")
  newx <- data.frame(seq(min(data[, IV]), max(data[, IV]), length=slices))
  colnames(newx) <- IV
  l0.boot <- matrix(NA, nrow=nrow(newx), ncol=B)
  
  l0 <- method(formula, data)
  for (i in 1:B) {
    data2 <- data[sample(nrow(data), replace=TRUE), ]
    data2 <- data2[order(data2[, IV]), ]
    if (class(l0)=="loess") {
      m1 <- method(formula, data2, control = loess.control(surface = "i", statistics="a", trace.hat="a"), ...)
    } else {
      m1 <- method(formula, data2, ...)
    }
    l0.boot[, i] <- predict(m1, newdata=newx)
  }
  
  # compute median and CI limits of bootstrap
  library(plyr)
  library(reshape2)
  CI.boot <- adply(l0.boot, 1, function(x) quantile(x, prob=c(.025, .5, .975, pnorm(c(-3, -2, -1, 0, 1, 2, 3))), na.rm=TRUE))[, -1]
  colnames(CI.boot)[1:10] <- c("LL", "M", "UL", paste0("SD", 1:7))
  CI.boot$x <- newx[, 1]
  CI.boot$width <- CI.boot$UL - CI.boot$LL
  
  # scale the CI width to the range 0 to 1 and flip it (bigger numbers = narrower CI)
  CI.boot$w2 <- (CI.boot$width - min(CI.boot$width))
  CI.boot$w3 <- 1-(CI.boot$w2/max(CI.boot$w2))
  
  
  # convert bootstrapped spaghettis to long format
  b2 <- melt(l0.boot)
  b2$x <- newx[,1]
  colnames(b2) <- c("index", "B", "value", "x")
  
  library(ggplot2)
  library(RColorBrewer)
  
  # Construct ggplot
  # All plot elements are constructed as a list, so they can be added to an existing ggplot
  
  # if add == FALSE: provide the basic ggplot object
  p0 <- ggplot(data, aes_string(x=IV, y=DV)) + theme_bw()
  
  # initialize elements with NULL (if they are defined, they are overwritten with something meaningful)
  gg.tiles <- gg.poly <- gg.spag <- gg.median <- gg.CI1 <- gg.CI2 <- gg.lm <- gg.points <- gg.title <- NULL
  
  if (shade == TRUE) {
    quantize <- match.arg(quantize, c("continuous", "SD"))
    if (quantize == "continuous") {
      print("Computing density estimates for each vertical cut ...")
      flush.console()
      
      if (is.null(ylim)) {
        min_value <- min(min(l0.boot, na.rm=TRUE), min(data[, DV], na.rm=TRUE))
        max_value <- max(max(l0.boot, na.rm=TRUE), max(data[, DV], na.rm=TRUE))
        ylim <- c(min_value, max_value)
      }
      
      # vertical cross-sectional density estimate
      d2 <- ddply(b2[, c("x", "value")], .(x), function(df) {
        res <- data.frame(density(df$value, na.rm=TRUE, n=slices, from=ylim[1], to=ylim[2])[c("x", "y")])
        #res <- data.frame(density(df$value, na.rm=TRUE, n=slices)[c("x", "y")])
        colnames(res) <- c("y", "dens")
        return(res)
      }, .progress="text")
      
      maxdens <- max(d2$dens)
      mindens <- min(d2$dens)
      d2$dens.scaled <- (d2$dens - mindens)/maxdens  
      
      ## Tile approach
      d2$alpha.factor <- d2$dens.scaled^shade.alpha
      gg.tiles <-  list(geom_tile(data=d2, aes(x=x, y=y, fill=dens.scaled, alpha=alpha.factor)), scale_fill_gradientn("dens.scaled", colours=palette), scale_alpha_continuous(range=c(0.001, 1)))
    }
    if (quantize == "SD") {
      ## Polygon approach
      
      SDs <- melt(CI.boot[, c("x", paste0("SD", 1:7))], id.vars="x")
      count <- 0
      d3 <- data.frame()
      col <- c(1,2,3,3,2,1)
      for (i in 1:6) {
        seg1 <- SDs[SDs$variable == paste0("SD", i), ]
        seg2 <- SDs[SDs$variable == paste0("SD", i+1), ]
        seg <- rbind(seg1, seg2[nrow(seg2):1, ])
        seg$group <- count
        seg$col <- col[i]
        count <- count + 1
        d3 <- rbind(d3, seg)
      }
      
      gg.poly <-  list(geom_polygon(data=d3, aes(x=x, y=value, color=NULL, fill=col, group=group)), scale_fill_gradientn("dens.scaled", colours=palette, values=seq(-1, 3, 1)))
    }
  }
  
  print("Build ggplot figure ...")
  flush.console()
  
  
  if (spag==TRUE) {
    gg.spag <-  geom_path(data=b2, aes(x=x, y=value, group=B), size=0.7, alpha=10/B, color=spag.color)
  }
  
  if (show.median == TRUE) {
    if (mweight == TRUE) {
      gg.median <-  geom_path(data=CI.boot, aes(x=x, y=M, alpha=w3^3), size=.6, linejoin="mitre", color=median.col)
    } else {
      gg.median <-  geom_path(data=CI.boot, aes(x=x, y=M), size = 0.6, linejoin="mitre", color=median.col)
    }
  }
  
  # Confidence limits
  if (show.CI == TRUE) {
    gg.CI1 <- geom_path(data=CI.boot, aes(x=x, y=UL), size=1, color="red")
    gg.CI2 <- geom_path(data=CI.boot, aes(x=x, y=LL), size=1, color="red")
  }
  
  # plain linear regression line
  if (show.lm==TRUE) {gg.lm <- geom_smooth(method="lm", color="darkgreen", se=FALSE)}
  
  gg.points <- geom_point(data=data, aes_string(x=IV, y=DV), size=1, shape=shape, fill="white", color="black")       
  
  if (title != "") {
    gg.title <- theme(title=title)
  }
  
  
  gg.elements <- list(gg.tiles, gg.poly, gg.spag, gg.median, gg.CI1, gg.CI2, gg.lm, gg.points, gg.title, theme(legend.position="none"))
  
  if (add == FALSE) {
    return(p0 + gg.elements)
  } else {
    return(gg.elements)
  }
}
library(ggplot2)
library(reshape2)
P1= vwReg(x ~ y,datos,palette = brewer.pal(6,"YlOrRd"))+
  labs(x = "Diamtro altura del pecho (cm)", y = "Altura total (m)", 
       caption = "*Coeficiente de correlación de Pearson")+

  stat_cor(method = "pearson",label.x.npc = "left")+
  geom_smooth(method = lm,se = FALSE, color="blue")+
  theme(axis.title.x = element_text(color="black", size=11,family="serif",face="bold"),
        axis.title.y = element_text(color="black", size=11,family="serif",face="bold"),
        axis.text.x  = element_text(color="black", size=10,family="serif"),
        axis.text.y  = element_text( color="black", size=10,family="serif"))
P1


HistoX= ggplot(datos, aes(x = x))+
  geom_histogram(bins =20, fill="#386641", color="black")+
  scale_y_continuous(limits = c(0, 30), expand = c(0, 0))+
  scale_x_continuous(limits = c(5, 14), expand = c(0, 0))+
  theme_void()
  
HistoX

Histoy= ggplot(datos, aes(x = y))+
  geom_histogram(bins =25, fill="#ff5400", color="black")+
  scale_y_continuous(limits = c(0, 15), expand = c(0, 0))+
  scale_x_continuous(limits = c(3.8, 12), expand = c(0, 0))+
  theme_void()+
  coord_flip()

Histoy

library(cowplot)
Expo = ggdraw() +
  coord_equal(xlim = c(0, 16.8), ylim = c(0, 16.5), expand = FALSE) +
  
  draw_plot(P1 , width = 14, height = 14,x = 0, y = 0)+
  draw_plot(HistoX, width = 12, height = 5,x = 1, y = 14)+
  draw_plot(Histoy, width = 4, height = 12,x = 14, y = 2)+
  
  
  theme(panel.background = element_rect(fill = "white"))

Expo

ggsave(plot=Expo ,"Grafico de Regresion lineal simple.png",units = "cm",width = 16.5, #ancho
       height = 16.8, #alargo
       dpi=1200)























